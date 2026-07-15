// macrec — record system audio (excluding self) + microphone, mix to 16kHz mono WAV.
//
// Usage:
//   macrec --out <path.wav> [--no-mic] [--duration <seconds>]
//   macrec mic-status        # prints "1" if the default input device is in use, else "0"
//
// Stops on SIGINT/SIGTERM (or after --duration), mixes the two sources, prints the final
// WAV path to stdout. All diagnostics go to stderr.
//
// Requires (macOS 15+): "System Audio Recording Only" permission (system audio via a Core Audio
// process tap, kTCCServiceAudioCapture) and Microphone permission. Built for macOS 26.

import Foundation
import AVFoundation
import CoreMedia
import Translation   // macOS 26 on-device translation of live captions
import Speech   // macOS 26 SpeechAnalyzer — real-time captions (whisper-cli stays the saved transcript)
import CoreAudio
import CoreGraphics
import AppKit
import EventKit
import ServiceManagement
import Security   // Keychain — API keys don't belong in UserDefaults
import UserNotifications   // completion push after a manual "Transcribe now"
import Compression   // zlib ratio — whisper repetition-loop detector (see Transcriber.scrubLines)

// MARK: - helpers

/// Credential store for long-lived API keys (openai / deepl / …). Backed by a **0600 JSON file** under
/// Application Support — NOT the login keychain. The keychain binds each item's ACL to the exact binary
/// that created it, and the modern `SecItemAdd` ignores a custom all-apps ACL, so a frequently-rebuilt
/// tool re-prompts "allow access" on every rebuild — unusable. These are low-sensitivity, user-revocable
/// keys on the user's own Mac (the posture of `~/.aws/credentials`, `gh`, `npm`); a plaintext 0600 file
/// never prompts. The `Keychain` name + API are kept so callers are unchanged.
enum Keychain {
    private static let lock = NSLock()
    private static var loaded = false
    private static var store: [String: String] = [:]
    private static var secretRequests = 0
    private static var reads = 0

    /// Set by the CLI subcommands that must never touch the user's real credentials (selftest, snapshots).
    nonisolated(unsafe) static var disabled = false
    /// Test hook: point the store at a throwaway file so a selftest can exercise real read/write/0600.
    nonisolated(unsafe) static var fileOverrideForTest: URL?

    /// ~/Library/Application Support/macrec/credentials.json (dir 0700). The override wins under test.
    private static var fileURL: URL {
        if let o = fileOverrideForTest { return o }
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("macrec", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return base.appendingPathComponent("credentials.json")
    }

    private static func loadIfNeeded() {   // caller holds lock
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        store = obj
    }

    private static func persist() {   // caller holds lock
        guard let data = try? JSONSerialization.data(withJSONObject: store, options: [.sortedKeys, .prettyPrinted])
        else { return }
        let url = fileURL
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { elog("cred: write '\(url.lastPathComponent)' failed: \(error)") }
    }

    /// Is a credential stored? Never prompts (a plain file read).
    static func exists(_ account: String) -> Bool {
        if disabled { return false }
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return store[account]?.isEmpty == false
    }

    static func get(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        secretRequests += 1
        if disabled { return nil }
        loadIfNeeded()
        guard let v = store[account], !v.isEmpty else { return nil }
        reads += 1
        return v
    }

    /// Empty value removes the key. Never prompts (a file write).
    @discardableResult
    static func set(_ account: String, _ value: String) -> Bool {
        if disabled { return true }
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        if value.isEmpty { store[account] = nil } else { store[account] = value }
        persist()
        return true
    }

    /// One-time cleanup: drop any orphaned items still in the OLD login keychain. Delete does NOT read the
    /// secret, so it does not prompt. The app no longer reads the keychain, so leaving them would be
    /// harmless too — this just keeps things tidy.
    static func purgeLegacyKeychain(_ accounts: [String]) {
        guard !disabled else { return }
        for a in accounts {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: "com.ikhoon.macrec",
                           kSecAttrAccount as String: a] as CFDictionary)
        }
    }

    static var secretRequestsForTest: Int { lock.lock(); defer { lock.unlock() }; return secretRequests }
    static var readsForTest: Int { lock.lock(); defer { lock.unlock() }; return reads }
    static func forgetCacheForTest() { lock.lock(); loaded = false; store = [:]; lock.unlock() }
}

/// An in-memory ring of the most recent log lines. stderr is redirected by launchd to a file whose path
/// the app never learns, so the in-app Log window tails THIS instead — the same lines `elog` writes to
/// stderr, kept for troubleshooting without leaving the app. Thread-safe (elog is called off many threads).
enum LogBuffer {
    private static let lock = NSLock()
    private static var lines: [String] = []
    static let cap = 4000

    static func append(_ s: String) {
        lock.lock()
        lines.append(s)
        if lines.count > cap { lines.removeFirst(lines.count - cap) }   // bound memory: keep the last `cap`
        lock.unlock()
    }

    static func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
    static func clear() { lock.lock(); lines.removeAll(keepingCapacity: true); lock.unlock() }
    static func countForTest() -> Int { lock.lock(); defer { lock.unlock() }; return lines.count }
}

func elog(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    LogBuffer.append(s)
}

// MARK: - permissions (preflighting these prevents startCapture() from hanging under launchd)

// System-audio capture uses Core Audio process taps, gated by kTCCServiceAudioCapture
// ("System Audio Recording Only") — NOT Screen Recording. No public API checks/requests it, so we
// use the private TCC SPI (as insidegui/AudioCap does); fine for a self-signed, non-App-Store tool.
private let tccHandle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
private let kAudioCaptureTCC = "kTCCServiceAudioCapture" as CFString

func audioCaptureAuthorized() -> Bool {
    guard let h = tccHandle, let sym = dlsym(h, "TCCAccessPreflight") else { return true }  // can't check → assume ok
    typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    return unsafeBitCast(sym, to: Preflight.self)(kAudioCaptureTCC, nil) == 0   // 0 authorized, 1 denied, 2 undetermined
}

func micAuthorized() -> Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

/// Fire the System-Audio-Recording + Microphone prompts (registers macrec in the TCC lists). Non-blocking-ish.
func requestPermissions() -> (audio: Bool, mic: Bool) {
    if let h = tccHandle, let sym = dlsym(h, "TCCAccessRequest") {
        typealias Request = @convention(c) (CFString, CFDictionary?, @convention(block) (Bool) -> Void) -> Void
        unsafeBitCast(sym, to: Request.self)(kAudioCaptureTCC, nil) { _ in }
    }
    var mic = micAuthorized()
    if !mic {
        let sem = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .audio) { granted in mic = granted; sem.signal() }
        _ = sem.wait(timeout: .now() + 3)  // don't block forever if no prompt can show
    }
    return (audioCaptureAuthorized(), mic)
}

/// Canonical processing format used everywhere: 16 kHz, mono, float32 (what Whisper wants).
let canon = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

// Retained for the lifetime of the process so the signal sources stay alive.
var signalSources: [DispatchSourceSignal] = []

// MARK: - mic-status (CoreAudio)

func defaultInputDevice() -> AudioDeviceID? {
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
    return st == noErr && dev != 0 ? dev : nil
}

func isRunningSomewhere(_ dev: AudioDeviceID) -> Bool {
    var running = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let st = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &running)
    return st == noErr && running != 0
}

func micStatus() -> Bool {
    guard let dev = defaultInputDevice() else { return false }
    return isRunningSomewhere(dev)
}

// MARK: - preferences (UserDefaults > env var > built-in default)
//
// The settings UI writes to UserDefaults. The headless `engine` CLI / power users can override via MR_* env vars.
// Precedence: UserDefaults (if the key exists) > env > built-in default.

/// Typed preference keys + accessors over a dedicated UserDefaults suite; fallback is accessor-specific
/// (generally saved pref → env var → built-in default, but e.g. Pref.str treats an empty saved string as unset).
enum Pref {
    // Dedicated suite (MUST differ from the bundle id — suiteName==bundleID returns nil / doesn't work).
    // Works around .standard domain not resolving when launchd execs the binary inside the .app directly.
    // To inspect from the CLI: `defaults read com.ikhoon.macrec.prefs`
    static let suiteName = "com.ikhoon.macrec.prefs"
    nonisolated(unsafe) static var d = UserDefaults(suiteName: suiteName) ?? .standard

    /// Point every read and write at a throwaway suite. The test and snapshot subcommands drive the real
    /// UI, which persists as it goes — `caption-snapshot` left the user in subtitle mode at zero opacity,
    /// and a later selftest then read that back and failed. A harness must not be able to change the app.
    static func useEphemeralStoreForTest() {
        let name = "com.ikhoon.macrec.ephemeral-test"
        UserDefaults.standard.removePersistentDomain(forName: name)
        d = UserDefaults(suiteName: name) ?? .standard
    }
    // Key constants (shared with the settings UI)
    static let segment = "segmentSeconds", voiceMin = "voiceMinSeconds", lang = "whisperLang"
    static let keepAudio = "keepAudio", audioRetention = "audioRetentionDays", txtRetention = "transcriptRetentionDays"
    static let audioRawDays = "audioRawDays"            // days a WAV stays raw before AAC compression (0 = never compress)
    static let exclude = "excludeApps", txtDir = "transcriptsDir", vad = "vadEnabled", autoStart = "autoStart"
    static let cal = "useCalendarTitles", model = "whisperModelName"
    static let calendars = "calendarNames"              // calendar titles to source event titles from (empty = all)
    static let liveSubtitle = "liveSubtitle"            // film-subtitle presentation (centred, last lines only)
    static let liveTimestamps = "liveTimestamps"        // show timestamps in the live-caption overlay
    static let captionLang = "liveCaptionLang"          // live-caption transcription locale ("" = system)
    static let translateTo = "liveTranslateTo"          // live-caption translation target ("" = off)
    static let translateProvider = "liveTranslateProvider"  // translation backend: apple|deepl (falls back to apple)
    static let ttsProvider = "liveTTSProvider"              // interpretation voice: apple (cloud pluggable later)
    static let interpretOutputUID = "liveInterpretOutputUID"  // Core Audio device UID the interpreted voice plays to
    static let liveFontSize = "liveFontSize"            // live-caption overlay font size (pt)
    static let liveOpacity = "liveOpacity"              // live-caption overlay opacity (0.3–1.0)
    static let liveBarCollapsed = "liveBarCollapsed"    // overlay control strip collapsed (space for captions)
    static let liveSource = "liveSource"                // which speakers to transcribe live: both|other|me
    static let liveEngine = "liveEngine"                // live transcription engine: apple|whisper|deepgram (extensible)
    static let liveEnginesOn = "liveEnginesOn"          // engines the user switched ON (absent = defaults)
    static let deepgramKey = "deepgramKey"              // LEGACY (pre-Keychain builds) — read once for migration, then removed
    static let openaiBase = "openaiBase"                // OpenAI-compatible base URL ("" = api.openai.com; e.g. a corporate proxy)
    static let autostartOffered = "autostartOffered"   // one-shot: auto-enabled the login item once
    static let systemAudio = "captureSystemAudio"       // capture other-party (system) audio via SCK
    static let echoReduce = "echoReduce"                // opt-in: duck speaker→mic echo using the tap as reference
    static let audioDir = "audioDir"                    // separate root for kept .wav (default OUTPUT_ROOT/audio)
    static let customModel = "customModelURL"           // custom model source (URL or local path) — overrides the popup
    static let transcriptLang = "transcriptLang"        // saved-transcript FILE language: ""=system|en|ko|ja (scaffold only)
    static let postProcessMode = "postProcessMode"      // off | summary (built-in) | shell (freeform)
    static let summaryRunner = "summaryRunner"          // automatic summary runner: claude | codex | gemini
    static let summaryPrompt = "summaryPrompt"          // summary prompt (absent = built-in default)
    static let summaryPromptFile = "summaryPromptFile"  // external prompt file — overrides the text when readable
    static let summaryOut = "summaryOut"                // summary output dir ("" = next to the transcript)
    static let dailyDigest = "dailyDigest"              // L3: write a daily digest of the day's summaries
    static let dailyDigestTime = "dailyDigestTime"      // "HH:mm" the digest becomes due (default 20:00)
    static let dailyDigestOut = "dailyDigestOut"        // digest output dir ("" = alongside the summaries)
    static let dailyDigestName = "dailyDigestName"      // digest file-name template ("" = "{date}.md")
    static let dailyPrompt = "dailyDigestPrompt"        // digest prompt (absent = built-in default)
    static let dailyPromptFile = "dailyDigestPromptFile"  // external prompt file — overrides when readable
    static let dailyDigestLastRun = "dailyDigestLastRun"  // "yyyy-MM-dd" marker — one digest per day
    static let autoUpdateCheck = "autoUpdateCheck"        // daily background release check (default on)
    static let updateCheckLastRun = "updateCheckLastRun"  // "yyyy-MM-dd" marker — one check per day
    static let postProcessCmd = "postProcessCmd"        // freeform command ("" = off)
    static let hintsTerms = "hintsTerms"                // transcription hint terms (comma/newline separated)
    static let hintsFile = "hintsFile"                  // external hints file (one term per line, # comments)
    static let hintsCalendar = "hintsCalendar"          // merge the overlapping event's title + attendees
    static let schedEnabled = "scheduleEnabled"         // record only on a schedule (default: 24/7)
    static let schedDays = "scheduleDays"               // e.g. "mon-fri" / "mon,wed,fri" / "sat,sun"
    static let schedHours = "scheduleHours"             // e.g. "10:00-12:00, 13:00-19:00" (gaps = excluded)
    static let calGated = "calendarGated"               // record only while a calendar meeting is live
    static let calGatePad = "calendarGatePadMin"        // minutes to record before/after a meeting (default 5)
    /// Explicit save (even empty) beats the env — for fields where empty is meaningful.
    static func explicit(_ key: String, _ env: String) -> String {
        if d.object(forKey: key) != nil { return d.string(forKey: key) ?? "" }
        return ProcessInfo.processInfo.environment[env] ?? ""
    }
    static var postProcessCommand: String { explicit(postProcessCmd, "MR_POST_PROCESS") }

    static func dbl(_ key: String, _ env: String, _ def: Double) -> Double {
        if d.object(forKey: key) != nil { return d.double(forKey: key) }
        if let e = ProcessInfo.processInfo.environment[env], let v = Double(e) { return v }
        return def
    }
    static func int(_ key: String, _ env: String, _ def: Int) -> Int {
        if d.object(forKey: key) != nil { return d.integer(forKey: key) }
        if let e = ProcessInfo.processInfo.environment[env], let v = Int(e) { return v }
        return def
    }
    static func str(_ key: String, _ env: String, _ def: String) -> String {
        if let s = d.string(forKey: key), !s.isEmpty { return s }
        if let e = ProcessInfo.processInfo.environment[env], !e.isEmpty { return e }
        return def
    }
    static func bool(_ key: String, _ env: String, _ def: Bool) -> Bool {
        if d.object(forKey: key) != nil { return d.bool(forKey: key) }
        if let e = ProcessInfo.processInfo.environment[env] { return (e as NSString).boolValue }
        return def
    }
}

// MARK: - bundled tools + model store

/// Resolves whisper-cli / VAD model shipped INSIDE the .app (self-contained distribution).
/// Returns nil in dev (loose binary) so EngineConfig falls back to brew / ~/whisper-models.
enum BundledTools {
    /// The .app bundle URL when running as Contents/MacOS/macrec (resolved from the executable path); nil for a loose CLI binary.
    static var appBundleURL: URL? {
        let u = Bundle.main.bundleURL
        return u.pathExtension == "app" ? u : nil
    }
    /// Contents/Helpers/whisper-cli inside the .app, if present + executable.
    static var whisperCli: String? {
        guard let app = appBundleURL else { return nil }
        let p = app.appendingPathComponent("Contents/Helpers/whisper-cli").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }
    /// Bundled silero VAD model (Contents/Resources), if present.
    static var vadModel: String? {
        Bundle.main.url(forResource: "ggml-silero-v5.1.2", withExtension: "bin")?.path
    }
}

/// A downloadable whisper.cpp GGML model. Filenames + sizes verified against ggerganov/whisper.cpp.
struct WhisperModelSpec {
    let name: String        // stable id stored in prefs (e.g. "large-v3-turbo")
    let filename: String    // ggml-<…>.bin on HuggingFace
    let label: String       // shown in the Settings popup
    let url: String         // download URL — empty means `filename` is a local absolute path (no download)
    let minBytes: Int64     // reject a download smaller than this (partials / HTML error pages)
    // Catalog entries pass `bytes` (verified size → minBytes = bytes/2) and get the ggerganov URL;
    // a custom model overrides `url`/`minBytes` explicitly.
    init(name: String, filename: String, label: String, bytes: Int64,
         url: String? = nil, minBytes: Int64? = nil) {
        self.name = name; self.filename = filename; self.label = label
        self.url = url ?? "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)"
        self.minBytes = minBytes ?? bytes / 2
    }
}

/// Curated, verified set of selectable models (best multilingual ko/ja/en picks first).
enum WhisperCatalog {
    static let defaultName = "large-v3-turbo"
    static let all: [WhisperModelSpec] = [
        .init(name: "large-v3-turbo",      filename: "ggml-large-v3-turbo.bin",      label: "Large v3 Turbo — fast + accurate ★ (1.6 GB)",       bytes: 1_624_555_275),
        .init(name: "large-v3-turbo-q5_0", filename: "ggml-large-v3-turbo-q5_0.bin", label: "Large v3 Turbo q5_0 — near-turbo, smaller (574 MB)", bytes:   574_041_195),
        .init(name: "large-v3",            filename: "ggml-large-v3.bin",            label: "Large v3 — max accuracy, slow (3.1 GB)",            bytes: 3_095_033_483),
        .init(name: "medium",              filename: "ggml-medium.bin",              label: "Medium — strong multilingual (1.5 GB)",             bytes: 1_533_763_059),
        .init(name: "small",               filename: "ggml-small.bin",               label: "Small — lighter, faster (465 MB)",                  bytes:   487_601_967),
        .init(name: "base",                filename: "ggml-base.bin",                label: "Base — fast, basic accuracy (141 MB)",              bytes:   147_951_465),
        .init(name: "tiny",                filename: "ggml-tiny.bin",                label: "Tiny — fastest, lowest accuracy (74 MB)",           bytes:    77_691_713),
    ]
    static func spec(_ name: String) -> WhisperModelSpec {
        all.first { $0.name == name } ?? all.first { $0.name == defaultName }!
    }
    /// Currently selected model. A non-empty custom source (Settings field / MR_MODEL_URL) — a URL or
    /// a local file path — overrides the catalog pick.
    static var selected: WhisperModelSpec {
        let custom = Pref.str(Pref.customModel, "MR_MODEL_URL", "").trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return customSpec(custom) }
        return spec(Pref.str(Pref.model, "MR_WHISPER_MODEL", defaultName))
    }

    /// Build a spec from a custom source: an http(s) URL → download; anything else → local file path.
    static func customSpec(_ src: String) -> WhisperModelSpec {
        if src.hasPrefix("http://") || src.hasPrefix("https://") {
            let base = URL(string: src)?.lastPathComponent ?? ""
            let fname = base.isEmpty ? "custom-model.bin" : base
            return WhisperModelSpec(name: "custom", filename: fname, label: "Custom", bytes: 0,
                                    url: src, minBytes: 1_000_000)   // ≥1MB to reject HTML/404 pages
        }
        let abs = (src as NSString).expandingTildeInPath
        return WhisperModelSpec(name: "custom", filename: abs, label: "Custom", bytes: 0,
                                url: "", minBytes: 1)                // local file: exists (≥1 byte)
    }
}

/// Downloads the selected transcription model on first run / on change (too big to bundle).
/// Stored under ~/Library/Application Support/macrec/models/, keyed by filename so
/// multiple models coexist and switching back never re-downloads.
final class ModelStore: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelStore()

    /// Download progress: 0...1 while running, 1.0 done, <0 failed. Delivered on the main queue.
    var onProgress: ((Double) -> Void)?
    private var session: URLSession?
    private var downloadingSpec: WhisperModelSpec?   // spec currently downloading (nil = idle)

    var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("macrec/models", isDirectory: true)
    }
    func path(for s: WhisperModelSpec) -> URL {
        s.filename.hasPrefix("/") ? URL(fileURLWithPath: s.filename)   // custom local file (absolute path)
                                  : dir.appendingPathComponent(s.filename)
    }
    func isReady(_ s: WhisperModelSpec) -> Bool { fileBytes(path(for: s)) >= s.minBytes }

    /// The currently-selected model.
    var spec: WhisperModelSpec { WhisperCatalog.selected }
    var isReady: Bool { isReady(spec) }

    /// Path EngineConfig should use for the current selection: App Support if present, else a dev
    /// ~/whisper-models copy, else the (not-yet-filled) App Support path so the download lands there.
    var resolvedModelPath: String {
        let s = spec
        if isReady(s) || s.url.isEmpty { return path(for: s).path }   // ready, or a local custom file
        let dev = devPath(s)
        if fileBytes(dev) >= s.minBytes { return dev.path }
        return path(for: s).path
    }

    private func devPath(_ s: WhisperModelSpec) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("whisper-models/\(s.filename)")
    }
    private func fileBytes(_ u: URL) -> Int64 {
        guard let a = try? FileManager.default.attributesOfItem(atPath: u.path) else { return 0 }
        return (a[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Download the current selection if missing. Idempotent; re-targets if the selection changed.
    func ensure() {
        let s = spec
        // Local custom file (empty url) or already-present model → nothing to download.
        if s.url.isEmpty || isReady(s) || fileBytes(devPath(s)) >= s.minBytes {
            if downloadingSpec != nil { cancelDownload() }
            return
        }
        if downloadingSpec?.url == s.url { return }               // already fetching this exact source
        if downloadingSpec != nil { cancelDownload() }            // switch download target

        downloadingSpec = s
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let url = URL(string: s.url) else { downloadingSpec = nil; return }
        let sess = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = sess
        elog("model: downloading \(s.name) \(s.url) → \(path(for: s).path)")
        sess.downloadTask(with: url).resume()
    }

    private func cancelDownload() {
        session?.invalidateAndCancel(); session = nil; downloadingSpec = nil
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
        guard s === session, t > 0 else { return }
        let p = Double(w) / Double(t)
        DispatchQueue.main.async { self.onProgress?(p) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo loc: URL) {
        guard s === session, let sp = downloadingSpec else { return }
        let size = fileBytes(loc)                       // temp file is deleted after we return — move now
        guard size >= sp.minBytes else {
            elog("model: \(sp.name) downloaded too small (\(size) bytes) — discarding"); finish(ok: false); return
        }
        let dst = path(for: sp)
        do {
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: loc, to: dst)
            elog("model: ready → \(dst.path) (\(size) bytes)")
            finish(ok: true)
        } catch { elog("model: move failed \(error)"); finish(ok: false) }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError err: Error?) {
        guard s === session else { return }   // ignore callbacks from a cancelled (switched) session
        if let err = err { elog("model: download failed \(err)"); finish(ok: false) }
    }

    private func finish(ok: Bool) {
        downloadingSpec = nil
        session?.finishTasksAndInvalidate(); session = nil
        DispatchQueue.main.async { self.onProgress?(ok ? 1.0 : -1) }
    }
}

// MARK: - engine config

/// The resolved recording configuration (segment length, dirs, model, language, exclusions…) the engine runs on.
struct EngineConfig {
    var segmentSeconds: Double
    var voiceMinSeconds: Double
    var transcriptsDir: URL
    var audioDir: URL
    var workDir: URL
    var whisperCli: String
    var whisperModel: String
    var vadModel: String
    var vadEnabled: Bool
    var useCalendarTitles: Bool         // title transcripts from the overlapping calendar event
    var whisperLang: String
    var keepAudio: Bool                 // false: keep only the transcript and delete the audio
    var audioRawDays: Int               // days a WAV stays raw before AAC compression (0 = never compress)
    var audioRetentionDays: Int         // 0 = unlimited
    var transcriptRetentionDays: Int    // 0 = unlimited
    var excludeBundleIds: [String]

    static func load() -> EngineConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tdir = URL(fileURLWithPath: Pref.str(Pref.txtDir, "MR_TRANSCRIPTS_DIR",
                                                 home.appendingPathComponent("Documents/macrec/transcripts").path))
        // `Pref.str` treats a saved empty string as "unset" and falls back to the default — so clearing
        // the "Never capture" field silently re-excluded Spotify. An explicit empty save means nothing
        // is excluded; the default only applies when the user has never touched the field.
        let exclRaw = Pref.d.object(forKey: Pref.exclude) != nil
            ? (Pref.d.string(forKey: Pref.exclude) ?? "")
            : (ProcessInfo.processInfo.environment["MR_EXCLUDE_APPS"] ?? "com.spotify.client")
        let excl = exclRaw.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        return EngineConfig(
            segmentSeconds: Pref.dbl(Pref.segment, "MR_SEGMENT_SECONDS", 3600),
            voiceMinSeconds: Pref.dbl(Pref.voiceMin, "MR_VOICE_MIN_SECONDS", 5),
            transcriptsDir: tdir,
            // Audio lives in its OWN root (separate from transcripts) — default OUTPUT_ROOT/audio
            // (sibling of transcripts), overridable via Settings / MR_AUDIO_DIR.
            audioDir: URL(fileURLWithPath: Pref.str(Pref.audioDir, "MR_AUDIO_DIR",
                                                    tdir.deletingLastPathComponent().appendingPathComponent("audio").path)),
            workDir: URL(fileURLWithPath: Pref.str("workDir", "MR_WORK_DIR", "/tmp/macrec-segments")),
            // Defaults prefer what's bundled in the .app (self-contained); env/UserDefaults still override.
            whisperCli: Pref.str("whisperCli", "MR_WHISPER_CLI", BundledTools.whisperCli ?? "/opt/homebrew/bin/whisper-cli"),
            whisperModel: Pref.str("whisperModel", "MR_WHISPER_GGML", ModelStore.shared.resolvedModelPath),
            vadModel: Pref.str("vadModel", "MR_VAD_MODEL",
                               BundledTools.vadModel ?? home.appendingPathComponent("whisper-models/ggml-silero-v5.1.2.bin").path),
            vadEnabled: Pref.bool(Pref.vad, "MR_VAD", true),
            useCalendarTitles: Pref.bool(Pref.cal, "MR_CALENDAR_TITLES", true),
            // Default ko, not auto: auto detects ONCE on the first window and pins a wrong guess
            // for the whole hour (a Korean broadcast decoded as English fed the repetition loop;
            // English announcements came out as katakana). English-heavy sessions can still switch
            // the pref — a per-track language is the planned proper fix.
            whisperLang: Pref.str(Pref.lang, "MR_WHISPER_LANG", "ko"),
            keepAudio: Pref.bool(Pref.keepAudio, "MR_KEEP_AUDIO", true),
            // Lossy transcoding must be OPT-IN for anyone who configured retention before this
            // feature existed — an upgrade must never start re-encoding a curated archive on its
            // own. Fresh installs get the 7-day default; migrated ones start at "Don't compress".
            audioRawDays: Pref.int(Pref.audioRawDays, "MR_AUDIO_RAW_DAYS",
                                   Pref.d.object(forKey: Pref.audioRetention) != nil ? 0 : 7),
            audioRetentionDays: Pref.int(Pref.audioRetention, "MR_AUDIO_RETENTION_DAYS", 90),
            transcriptRetentionDays: Pref.int(Pref.txtRetention, "MR_TRANSCRIPT_RETENTION_DAYS", 0),
            excludeBundleIds: excl)
    }
}

// MARK: - completed segment + continuous capture session

/// One finished capture segment: its start time + the system/mic WAV files, awaiting transcription.
struct CompletedSegment {
    let start: Date
    let sysURL: URL
    let micURL: URL
    let micVoicedSeconds: Double
    let sysVoicedSeconds: Double
    let micSpeechSeconds: Double   // time inside sustained (>=256 ms) envelope runs — clicks contribute ~0
    let sysSpeechSeconds: Double
    let sysPeak: Float
    let micPeak: Float
    let durationSeconds: Double
    /// Either side speaking is worth transcribing (covers listen-only meetings where only sys speaks).
    var voicedSeconds: Double { max(micVoicedSeconds, sysVoicedSeconds) }
    var speechSeconds: Double { max(micSpeechSeconds, sysSpeechSeconds) }   // sustained envelope only (clicks ≈ 0)
}

func segFormatter() -> DateFormatter {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd-HHmmss"; return f
}

// MARK: - system-audio capture (Core Audio process tap — "System Audio Recording Only")

/// Captures the system audio mix via a Core Audio process tap + private aggregate device (macOS
/// 14.4+). Needs only kTCCServiceAudioCapture — no Screen Recording, no orange dot. Excludes our
/// own process (and any excluded apps, e.g. Spotify) so we don't record ourselves / that app.
/// Verdict for `macrec tap-probe`. A tap aggregate delivers NO IOProc callbacks while no tapped
/// process renders audio — so zero buffers in silence is NOT "aggregate dead" (the probe's first
/// version said exactly that and misdiagnosed a healthy tap). Only a missing callback stream WHILE
/// our own test tone played condemns the aggregate; callbacks carrying only zeros mean the tap
/// itself is muted/broken (the tap-mute P0's signature). Pure + testable.
func tapProbeVerdict(buffers: Int, peak: Float, tonePlayed: Bool) -> (line: String, code: Int32) {
    if buffers == 0 {
        return tonePlayed
            ? ("NO CALLBACKS while the test tone played — aggregate/tap dead", 2)
            : ("no callbacks, and the test tone could not play — inconclusive; play any audio and re-run", 4)
    }
    if peak < 0.001 { return ("callbacks but SILENCE — tap delivers empty audio", 3) }
    return ("AUDIO CAPTURED", 0)
}

final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private let ioQueue = DispatchQueue(label: "macrec.systap")
    private let excludeBundleIds: [String]
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    /// The exclusion set is baked into an immutable `CATapDescription` at tap creation, so it goes stale
    /// the moment an excluded app launches or relaunches with a new pid. `CaptureSession` compares this
    /// against a fresh scan to decide whether the tap must be rebuilt. Our own process is always
    /// excluded and is not part of this comparison.
    private(set) var matchedExclusions: [AudioObjectID] = []
    /// The default output device UID the aggregate was pinned to at creation. Frozen like the exclusion
    /// set: when the system default output moves, the aggregate keeps pulling the OLD device, so this is
    /// compared against the live default to decide a rebuild.
    private(set) var pinnedOutputUID: String?
    /// True only when the tap-only aggregate could not start and the old device-bound shape was used —
    /// the shape that silenced direct playback on a USB DAC (see start()).
    private(set) var deviceBound = false

    init(excludeBundleIds: [String], onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.excludeBundleIds = excludeBundleIds
        self.onBuffer = onBuffer
    }

    func start() throws {
        stop()   // idempotent
        var exclude: [AudioObjectID] = []
        if let me = Self.processObject(pid: getpid()) { exclude.append(me) }
        // Match on Core Audio's own process list: AppKit only knows registered *applications*, never the
        // helper processes many apps actually play through.
        let procs = Self.audioProcesses()
        let matched = matchExcludedProcesses(procs, excludeBundleIds: excludeBundleIds)
        matchedExclusions = matched
        exclude.append(contentsOf: matched)
        for bid in excludeBundleIds where !procs.contains(where: { $0.bundleID == bid }) {
            elog("engine: exclude '\(bid)' — no audio process with that bundle id right now")
        }
        let desc = Self.tapDescription(excludeObjects: exclude)

        var tap = AudioObjectID(kAudioObjectUnknown)
        var st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr, tap != kAudioObjectUnknown else { throw Self.err("create tap", st) }
        tapID = tap
        guard let fmt = Self.tapFormat(tap) else { stop(); throw Self.err("tap format", -1) }
        format = fmt

        let outDevID = defaultOutputDeviceID()
        let outUID = outputDeviceUID(outDevID)
        pinnedOutputUID = outUID   // remember what we pinned, so a later default-output change is detectable
        // DEVICE-BOUND aggregate (the output device is the aggregate's clock). A tap-only aggregate was
        // tried as the fix for tapped-playback silence and it created and started fine — but its IOProc
        // delivered nothing: every segment recorded sys≈0 until a real call went untranscribed. The
        // silence bug was the TAP's mute default, fixed by the explicit .unmuted above, not the device
        // binding. Measured on this codebase: device binding is required for capture.
        func makeAggregate(bindDevice: Bool) -> [String: Any] {
            var d: [String: Any] = [
                kAudioAggregateDeviceNameKey: "macrec-tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString,
                                                   kAudioSubTapDriftCompensationKey: bindDevice]],
                kAudioAggregateDeviceTapAutoStartKey: true,
            ]
            if bindDevice {
                d[kAudioAggregateDeviceMainSubDeviceKey] = outUID as Any
                d[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outUID as Any]]
            }
            return d
        }
        deviceBound = true
        var agg = AudioObjectID(kAudioObjectUnknown)
        st = AudioHardwareCreateAggregateDevice(makeAggregate(bindDevice: true) as CFDictionary, &agg)
        guard st == noErr, agg != kAudioObjectUnknown else { stop(); throw Self.err("create aggregate", st) }
        aggID = agg

        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inData, _, _, _ in
            guard let self = self, let fmt = self.format,
                  let src = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inData, deallocator: nil),
                  src.frameLength > 0,
                  let copy = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: src.frameLength) else { return }
            copy.frameLength = src.frameLength   // no-copy buffer is only valid in this callback → copy it
            let s = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: src.audioBufferList))
            let d = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for i in 0..<min(s.count, d.count) where s[i].mData != nil && d[i].mData != nil {
                memcpy(d[i].mData, s[i].mData, Int(min(s[i].mDataByteSize, d[i].mDataByteSize)))
            }
            self.onBuffer(copy)
        }
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, ioQueue, ioBlock)
        guard st == noErr, let p = procID else { stop(); throw Self.err("create IOProc", st) }
        st = AudioDeviceStart(aggID, p)
        guard st == noErr else { stop(); throw Self.err("device start", st) }
        elog("engine: system-audio tap started (\(Int(fmt.sampleRate))Hz \(fmt.channelCount)ch, excluding \(exclude.count) procs, \(deviceBound ? "device-bound" : "tap-only")) → default output '\(outputDeviceName(outDevID))'")
    }

    /// The tap description, in one selftested place. stereoGlobalTapButExcludeProcesses = the whole
    /// system mix minus these processes. muteBehavior is EXPLICITLY .unmuted: on macOS 26 the
    /// default silences the tapped playback of every app system-wide (#132) — and the line was once
    /// lost in a refactor, which put Zoom on mute for a whole evening. The selftest pins it now.
    static func tapDescription(excludeObjects: [AudioObjectID]) -> CATapDescription {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeObjects)
        desc.uuid = UUID(); desc.isPrivate = true
        desc.muteBehavior = .unmuted
        return desc
    }

    func stop() {
        if aggID != kAudioObjectUnknown, let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
        ioQueue.sync {}   // drain in-flight IO blocks so counters read after stop() are final
        procID = nil
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = kAudioObjectUnknown }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
    }

    /// Every process Core Audio currently tracks as audio-capable, with the bundle id it attributes to
    /// each. The HAL populates this the moment a process opens an audio client, helpers included.
    static func audioProcesses() -> [AudioProcessInfo] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.map { AudioProcessInfo(objectID: $0, bundleID: Self.processBundleID($0)) }
    }

    private static func processBundleID(_ obj: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: CFString?
        let st = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
        }
        guard st == noErr, let s = cf as String?, !s.isEmpty else { return nil }
        return s
    }

    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var pidVar = pid
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            UInt32(MemoryLayout<pid_t>.size), &pidVar, &size, &obj)
        return (st == noErr && obj != kAudioObjectUnknown) ? obj : nil
    }
    private static func tapFormat(_ tap: AudioObjectID) -> AVAudioFormat? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd) == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }
    private static func err(_ what: String, _ st: OSStatus) -> NSError {
        NSError(domain: "macrec.systap", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "\(what) failed (\(st))"])
    }
}

/// Continuous capture whose per-source writers are swapped on a timer (hourly rotation), so capture
/// never stops and there are no gaps. System audio via a Core Audio tap ("System Audio Recording
/// Only" permission); mic via a separate AVCaptureSession.
///
/// The echo canceller's far-end reference must be what the SPEAKERS play. The transcript tap omits
/// `excludeBundleIds`, so an excluded app (playing out loud) is missing from it and its bleed into the
/// mic can never be cancelled. So when echo reduction is on AND something is excluded, we stand up a
/// SECOND tap that excludes only our own process — the full speaker mix — and route the reference through
/// it instead. With nothing excluded the filtered tap already IS the full mix, so the extra tap is moot.
/// Pure + selftested; the CaptureSession wiring below follows this decision exactly.
func shouldStartReferenceTap(echoReduceEnabled: Bool, hasExcludedApps: Bool) -> Bool {
    echoReduceEnabled && hasExcludedApps
}

/// Owns the live audio capture — the system-audio tap(s) + mic — feeding the writers and echo canceller.
final class CaptureSession {
    private var tap: SystemAudioTap?
    /// A second tap that excludes ONLY our own process — the full speaker mix — feeding the echo
    /// canceller the far-end signal it needs. The transcript's `tap` above still omits excludeBundleIds,
    /// so what gets recorded is unchanged; this only exists while echo reduction is on.
    private var referenceTap: SystemAudioTap?
    private let mic = MicCapture()
    let rec = Recorder(sysWriter: nil, micWriter: nil)
    private let excludeBundleIds: [String]
    private let workDir: URL
    private var segStart = Date()

    init(excludeBundleIds: [String], workDir: URL) {
        self.excludeBundleIds = excludeBundleIds
        self.workDir = workDir
    }

    private func base(_ start: Date) -> String {
        workDir.appendingPathComponent("seg-" + segFormatter().string(from: start)).path
    }
    private func openWriters(_ start: Date) throws {
        rec.sysWriter = try SourceWriter(url: URL(fileURLWithPath: base(start) + ".sys.wav"))
        rec.micWriter = try SourceWriter(url: URL(fileURLWithPath: base(start) + ".mic.wav"))
    }

    func start() async throws {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        segStart = Date()
        try openWriters(segStart)
        try startTap()
        try mic.start(into: rec)   // separate mic path (AVCaptureSession)
    }

    /// Start the system-audio Core Audio tap, unless system-audio capture is disabled (mic-only).
    private func startTap() throws {
        guard Pref.bool(Pref.systemAudio, "MR_SYSTEM_AUDIO", true) else {
            elog("engine: system-audio capture OFF (mic-only)")
            rec.referenceComesFromFullMixTap = false   // no system tap at all → the flag must not linger true
            return
        }
        let t = SystemAudioTap(excludeBundleIds: excludeBundleIds) { [weak self] buf in self?.rec.appendSys(buf) }
        try t.start()
        tap = t
        try startReferenceTap()
    }

    /// The AEC reference tap: the full speaker mix (only our own pid excluded), feeding the echo
    /// canceller so it can cancel even an app the transcript tap leaves out. Only while echo reduction
    /// is on; a failure here degrades to the filtered reference rather than killing capture.
    private func startReferenceTap() throws {
        referenceTap?.stop(); referenceTap = nil
        // Filtered mix owns the reference until a full-mix tap is proven live — so any window where the
        // filtered tap is already delivering but the reference tap isn't up yet falls back correctly.
        rec.referenceComesFromFullMixTap = false
        guard shouldStartReferenceTap(echoReduceEnabled: EchoCanceller.shared.enabled,
                                      hasExcludedApps: !excludeBundleIds.isEmpty) else { return }
        let r = SystemAudioTap(excludeBundleIds: []) { buf in EchoCanceller.shared.pushReference(buf) }
        // Hand the reference to the full-mix tap BEFORE it can fire, so appendSys yields first and the two
        // never push the same instant (a double feed corrupts the FIFO pairing). Revert if start fails.
        rec.referenceComesFromFullMixTap = true
        do { try r.start(); referenceTap = r }
        catch {
            rec.referenceComesFromFullMixTap = false
            elog("engine: AEC reference tap failed (\(error)) — falling back to the filtered mix")
        }
    }

    /// Rebuild the tap + mic (e.g. resuming after sleep/wake). Keeps the current writers running.
    func restartStream() async -> Bool {
        tap?.stop(); tap = nil
        referenceTap?.stop(); referenceTap = nil   // startTap rebuilds it; drop the old one so a failure leaves none
        do { try startTap(); try mic.start(into: rec); return true }
        catch { elog("engine: tap restart failed: \(error)"); return false }
    }

    /// An excluded app that launches (or relaunches with a new pid) AFTER the tap was created is not
    /// excluded by it — `CATapDescription` freezes a set of process object IDs. Rebuild the tap only
    /// when the set it should exclude has actually drifted, so an unrelated app launching costs nothing.
    func refreshTapIfStale() async {
        guard let live = tap else { return }
        let current = matchExcludedProcesses(SystemAudioTap.audioProcesses(), excludeBundleIds: excludeBundleIds)
        let curOut = outputDeviceUID(defaultOutputDeviceID())
        guard shouldRebuildTap(currentExclusions: current, liveExclusions: live.matchedExclusions,
                               currentOutputUID: curOut, liveOutputUID: live.pinnedOutputUID) else { return }
        // Say WHICH drifted — the output case is the one that used to be missed entirely.
        let why = tapOutputIsStale(current: curOut, live: live.pinnedOutputUID)
            ? "default output changed (\(live.pinnedOutputUID ?? "?") → \(curOut ?? "?"))"
            : "exclusion set changed (\(live.matchedExclusions.count) → \(current.count))"
        elog("engine: \(why) — rebuilding the tap")
        _ = await restartStream()
    }

    /// Pause capture (mic + both system taps) on lock/sleep.
    func suspendStream() async {
        mic.stop()
        tap?.stop(); tap = nil
        referenceTap?.stop(); referenceTap = nil
        rec.referenceComesFromFullMixTap = false
    }

    /// Snapshot the current writers into a CompletedSegment and (if `continueRecording`) swap in fresh
    /// writers for the next segment — all on the audio queue so no append races the swap.
    private func cut(continueRecording: Bool) -> CompletedSegment? {
        var done: CompletedSegment?
        let now = Date()
        rec.queue.sync {
            guard let sys = rec.sysWriter, let mic = rec.micWriter else { return }
            done = CompletedSegment(start: segStart, sysURL: sys.url, micURL: mic.url,
                                    micVoicedSeconds: mic.voicedSeconds, sysVoicedSeconds: sys.voicedSeconds,
                                    micSpeechSeconds: mic.speechSeconds, sysSpeechSeconds: sys.speechSeconds,
                                    sysPeak: sys.peak, micPeak: mic.peak,
                                    durationSeconds: now.timeIntervalSince(segStart))
            if continueRecording {
                do { try openWriters(now); segStart = now }
                catch { elog("rotate: new writer error: \(error)"); rec.sysWriter = nil; rec.micWriter = nil }
            } else {
                rec.sysWriter = nil; rec.micWriter = nil
            }
            // old writers drop their last ref here → AVAudioFile deinit flushes WAV headers
        }
        return done
    }

    func rotate() -> CompletedSegment? { cut(continueRecording: true) }

    func stop() async -> CompletedSegment? {
        mic.stop()
        let done = cut(continueRecording: false)
        tap?.stop(); tap = nil
        referenceTap?.stop(); referenceTap = nil
        rec.referenceComesFromFullMixTap = false   // symmetry with suspendStream: no tap live → flag false
        return done
    }
}

/// Filesystem-relative path from a directory to a file (e.g. transcripts/2026-07 → audio/2026-07/x.wav
/// yields "../../audio/2026-07/x.wav"), so the audio link works from the .md wherever the roots sit.
func relativePath(fromDir: URL, toFile: URL) -> String {
    let a = fromDir.standardizedFileURL.pathComponents
    let b = toFile.standardizedFileURL.pathComponents
    var i = 0
    while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
    let ups = Array(repeating: "..", count: max(0, a.count - i))
    return (ups + b[i...]).joined(separator: "/")
}

/// Filesystem-safe short slug from an event title (for the transcript filename). Keeps letters
/// (incl. Hangul/CJK) and digits; turns spaces into '-'; drops punctuation/emoji; caps length.
func slugify(_ s: String) -> String {
    var out = ""
    for ch in s {
        if ch.isLetter || ch.isNumber { out.append(ch) }
        else if ch == " " || ch == "-" || ch == "_" { out.append("-") }
    }
    while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
    out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if out.count > 40 { out = String(out.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
    return out.isEmpty ? "meeting" : out
}

/// One process Core Audio knows about, and the bundle id Core Audio attributes to it.
struct AudioProcessInfo: Equatable { let objectID: AudioObjectID; let bundleID: String? }

/// The audio processes an exclusion list should silence. Matching happens on Core Audio's own process
/// list, so a helper process that plays audio under its own bundle id is at least VISIBLE here — the
/// old AppKit lookup could not see it at all, which is why an "excluded" app kept being recorded.
/// A process with no bundle id (system mixers, our own tap) is never excluded. Pure + selftested.
func matchExcludedProcesses(_ processes: [AudioProcessInfo], excludeBundleIds: [String]) -> [AudioObjectID] {
    let want = Set(excludeBundleIds)
    return processes.filter { p in p.bundleID.map { want.contains($0) } ?? false }.map(\.objectID)
}

/// Has the set of processes an exclusion list resolves to drifted from what the live tap was built
/// with? `CATapDescription`'s exclusion is a frozen set of object IDs, so a relaunched (new pid) or
/// newly-started excluded app is simply not excluded until the tap is rebuilt. Pure + selftested.
func tapExclusionIsStale(current: [AudioObjectID], live: [AudioObjectID]) -> Bool {
    Set(current) != Set(live)
}

/// Has the default output device the tap's aggregate was pinned to moved? The aggregate wraps a specific
/// output device; when the system default output changes (headphones, a virtual/BlackHole device, a
/// per-app router like SoundSource) the frozen aggregate keeps pulling from the OLD device and the tap
/// goes silent or captures the wrong mix. Pure + selftested.
func tapOutputIsStale(current: String?, live: String?) -> Bool { current != live }

/// Rebuild the live tap when EITHER the excluded-process set OR the pinned output device has drifted — a
/// `CATapDescription` + private aggregate freeze BOTH, so neither self-heals. The exclusion guard used to
/// be the whole test; the output half was the missing case (a mid-meeting output switch never rebuilt).
/// Pure + selftested.
func shouldRebuildTap(currentExclusions: [AudioObjectID], liveExclusions: [AudioObjectID],
                      currentOutputUID: String?, liveOutputUID: String?) -> Bool {
    tapExclusionIsStale(current: currentExclusions, live: liveExclusions)
        || tapOutputIsStale(current: currentOutputUID, live: liveOutputUID)
}

/// Transcript/audio file base: the START time only — "2026-07-05-2100". The end time briefly
/// lived in the name too (start-end for mid-hour "Transcribe now" cuts) but read as clutter
/// (user pick); the header inside the file still carries the full start–end range.
func transcriptBaseName(start: Date, timeZone: TimeZone = .current) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone
    f.dateFormat = "yyyy-MM-dd-HHmm"
    return f.string(from: start)
}

/// The mapped event's start, clamped to `[segStart, segEnd]` — unclamped, consecutive slices of one
/// meeting collapse onto the same file name. No event → the segment's own start. Pure + selftested.
func transcriptStart(segStart: Date, segEnd: Date, eventStart: Date?) -> Date {
    guard let e = eventStart else { return segStart }
    return min(max(e, segStart), segEnd)
}
/// Checks GitHub for a newer release and reports back on the main queue.
enum UpdateChecker {
    static let releasesURL = "https://github.com/ikhoon/macrec/releases/latest"

    /// Ask GitHub for the latest release tag. Calls back on the MAIN queue with (tag, url) — nil
    /// tag = network/parse failure (reported only for manual checks, silent for background ones).
    static func fetchLatest(_ done: @escaping (String?, String?) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/ikhoon/macrec/releases/latest")!)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var tag: String?, url: String?
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                tag = obj["tag_name"] as? String
                url = obj["html_url"] as? String
            }
            DispatchQueue.main.async { done(tag, url) }
        }.resume()
    }

    /// Homebrew-cask installs should upgrade through brew (so the cask stays in sync); zip installs
    /// go to the releases page. Detection = the Caskroom directory existing.
    static var installedViaBrew: Bool {
        FileManager.default.fileExists(atPath: "/opt/homebrew/Caskroom/macrec")
    }
}

/// Sidebar search: which panes match the query? Case-insensitive substring against every visible
/// string in the pane (title, labels, captions, button titles) — typing "prompt" surfaces
/// Post-process. Empty query = all panes, original order. Pure + testable.
func settingsSearchHits(query: String, index: [[String]]) -> [Int] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return Array(index.indices) }
    return index.indices.filter { i in index[i].contains { $0.lowercased().contains(q) } }
}

/// Manages launch-at-login (SMAppService), deferring to the dev LaunchAgent when one owns autostart.
enum LoginItem {
    /// The dev LaunchAgent (install.sh). When present, launchd owns autostart — not us.
    static var managedByLaunchAgent: Bool {
        let p = ("~/Library/LaunchAgents/com.ikhoon.macrec.plist" as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: p)
    }

    @available(macOS 13, *)
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// Apply desired on/off, registering/unregistering only on an actual change. Returns the
    /// resulting status (may be .requiresApproval — caller can deep-link to System Settings).
    /// macOS reports a user-disabled item as .notFound, so we key off the real status, never a cache.
    @available(macOS 13, *)
    @discardableResult
    static func setEnabled(_ on: Bool) -> SMAppService.Status {
        let svc = SMAppService.mainApp
        let cur = svc.status
        do {
            if on {
                if cur != .enabled && cur != .requiresApproval { try svc.register() }
            } else {
                if cur == .enabled || cur == .requiresApproval { try svc.unregister() }
            }
        } catch { elog("login item \(on ? "register" : "unregister") failed: \(error)") }
        return svc.status
    }

    @available(macOS 13, *)
    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// First-run only: enable autostart for the DISTRIBUTED app (no LaunchAgent, running from a
    /// stable location — /Applications for the .zip download, or the Homebrew Cellar for `brew
    /// install` — never registered before). A one-shot flag means a later user opt-out in System
    /// Settings is never silently overridden.
    static func autoEnableOnceIfDistributed() {
        guard #available(macOS 13, *) else { return }
        guard !managedByLaunchAgent else { return }                         // dev machine: launchd owns it
        let loc = Bundle.main.bundleURL.resolvingSymlinksInPath().path      // resolve the brew opt→Cellar symlink
        guard loc.hasPrefix("/Applications/") || loc.contains("/Cellar/macrec/") else { return }  // stable location only
        guard !Pref.d.bool(forKey: Pref.autostartOffered) else { return }   // only ever auto-enable once
        Pref.d.set(true, forKey: Pref.autostartOffered)
        guard status != .enabled, status != .requiresApproval else { return }  // don't touch an already-on item
        _ = setEnabled(true)
        elog("login item: auto-enabled on first run (status=\(status))")
    }
}

/// Localized speaker labels — (mine = the microphone / you, theirs = the other party / system audio)
/// — for a language code. Falls back to English so non-Korean users don't see Korean labels.
func speakerLabels(forLanguage lang: String?) -> (mine: String, theirs: String) {
    switch lang {
    case "ko": return ("나", "상대")
    case "ja": return ("私", "相手")
    case "zh": return ("我", "对方")
    default:   return ("Me", "Them")
    }
}

/// Localized scaffold strings for the SAVED transcript markdown (headings, metadata labels, notes).
/// This is the FILE's language — the transcript body's speaker labels follow the transcription
/// language separately (see `speakerLabels`). Pure + testable (see `macrec selftest`).
struct TranscriptL10n {
    let code: String
    let autoTitle: String            // title fallback when no calendar event matches
    let time: String, speech: String, model: String
    let audio: String, audioNotKept: String
    let meetingLink: String, attendees: String, tags: String
    let section: String              // the transcript heading ("## …")
    let notesSection: String         // the calendar meeting-notes heading ("## …")

    static func forLanguage(_ raw: String?) -> TranscriptL10n {
        switch raw.map({ String($0.lowercased().prefix(2)) }) {
        case "ko": return .init(code: "ko", autoTitle: "자동 전사", time: "시각", speech: "발화", model: "모델",
                                audio: "오디오", audioNotKept: "_(보관 안 함)_", meetingLink: "회의 링크",
                                attendees: "참석자", tags: "태그", section: "## 전사 (transcript)",
                                notesSection: "## 미팅 노트 (calendar)")
        case "ja": return .init(code: "ja", autoTitle: "自動文字起こし", time: "時刻", speech: "発話", model: "モデル",
                                audio: "音声", audioNotKept: "_(保存なし)_", meetingLink: "会議リンク",
                                attendees: "参加者", tags: "タグ", section: "## 文字起こし (transcript)",
                                notesSection: "## ミーティングノート (calendar)")
        default:   return .init(code: "en", autoTitle: "Auto transcript", time: "Time", speech: "Speech", model: "Model",
                                audio: "Audio", audioNotKept: "_(not kept)_", meetingLink: "Meeting link",
                                attendees: "Attendees", tags: "Tags", section: "## Transcript",
                                notesSection: "## Meeting notes (calendar)")
        }
    }
    /// The configured code: an EXPLICITLY saved value (even empty = "follow the system language")
    /// beats the MR_TRANSCRIPT_LANG env — otherwise Settings couldn't restore System over the env.
    static var configuredCode: String {
        if Pref.d.object(forKey: Pref.transcriptLang) != nil { return Pref.d.string(forKey: Pref.transcriptLang) ?? "" }
        return ProcessInfo.processInfo.environment["MR_TRANSCRIPT_LANG"] ?? ""
    }
    static var current: TranscriptL10n {
        let pref = configuredCode
        return forLanguage(pref.isEmpty ? Locale.current.language.languageCode?.identifier : pref)
    }

    func minutes(_ n: Int) -> String {
        switch code { case "ko": return "\(n)분"; case "ja": return "\(n)分"; default: return "\(n) min" }
    }
    /// The blockquote note under the title. `mine`/`theirs` are the labels ACTUALLY used in the body
    /// (they follow the transcription language, not this file language).
    func recordingNote(mine: String, theirs: String, excludes: String) -> String {
        switch code {
        case "ko": return "> [연속 녹음] whisper-cli 자동 전사 (화자: \(mine)=마이크, \(theirs)=시스템)."
                        + (excludes.isEmpty ? "" : " \(excludes) 제외.")
        case "ja": return "> [連続録音] whisper-cli による自動文字起こし（話者: \(mine)=マイク、\(theirs)=システム音声）。"
                        + (excludes.isEmpty ? "" : " \(excludes) は除外。")
        default:   return "> [Continuous recording] Auto-transcribed by whisper-cli (speakers: \(mine) = microphone, \(theirs) = system audio)."
                        + (excludes.isEmpty ? "" : " Excluded: \(excludes).")
        }
    }
    func failureNote(model: String) -> String {
        switch code {
        case "ko": return "_(전사 실패 — whisper-cli/모델 확인: \(model))_"
        case "ja": return "_(文字起こし失敗 — whisper-cli/モデルを確認: \(model))_"
        default:   return "_(transcription failed — check whisper-cli/model: \(model))_"
        }
    }
}

/// Everything the saved transcript file contains, assembled into markdown by `markdown(_:)`.
/// Pure + testable — `writeTranscript` only does the IO around it. (The old hardcoded footer
/// ("auto-generated; distill reusable knowledge into topics/") is intentionally GONE: the app has no
/// business prescribing the user's post-processing workflow.)
struct TranscriptDoc {
    var title: String
    var day: String, hmStart: String, hmEnd: String, mins: Int
    var micVoiced: Double, sysVoiced: Double, modelName: String
    var audioLine: String, meta: String, excludes: String
    var bodyMine: String, bodyTheirs: String
    var body: String
    var eventNotes: String?   // the calendar event's notes — context the summarizer reads too

    func markdown(_ t: TranscriptL10n) -> String {
        let notesBlock = eventNotes.map { "\n\(t.notesSection)\n\n\($0)\n" } ?? ""
        return """
        # \(day) \(hmStart)–\(hmEnd) — \(title)

        \(t.recordingNote(mine: bodyMine, theirs: bodyTheirs, excludes: excludes))

        - \(t.time): \(day) \(hmStart)–\(hmEnd) (\(t.minutes(mins)))
        - \(t.speech): mic \(String(format: "%.1f", micVoiced))s · sys \(String(format: "%.1f", sysVoiced))s · \(t.model): `\(modelName)`
        \(audioLine)\(meta)
        - \(t.tags): #transcript #auto
        \(notesBlock)
        \(t.section)

        \(body)
        """
    }
}

/// Pick the best BCP-47 locale from `pool` for `requested` — exact match → same-language+same-region
/// → same-language (preferring -US then -GB) → nil. Pure + testable (see `macrec selftest`); used to
/// map `Locale.current` (which can be an unsupported region like en_KR) to a supported speech locale.
func pickSpeechLocale(requested: Locale, from pool: [Locale]) -> Locale? {
    let reqBCP = requested.identifier(.bcp47)
    if let exact = pool.first(where: { $0.identifier(.bcp47) == reqBCP }) { return exact }
    let lang = requested.language.languageCode?.identifier
    let same = pool.filter { $0.language.languageCode?.identifier == lang }
    if let r = requested.region?.identifier, let m = same.first(where: { $0.region?.identifier == r }) { return m }
    return same.first(where: { $0.identifier(.bcp47).hasSuffix("-US") })
        ?? same.first(where: { $0.identifier(.bcp47).hasSuffix("-GB") }) ?? same.first
}

// MARK: - menu-bar app (tray icon)

/// After a manual "Transcribe now" the menu CLOSES like any native item (user pick over the old
/// stay-open custom view), so the outcome arrives as a notification instead of an in-menu status.
/// Maps a segment status to the push it deserves; nil = intermediate ("Transcribing…"), keep waiting.
func flushOutcome(for status: String) -> (title: String, body: String)? {
    if status.hasPrefix("Saved: ") {
        return ("Transcript ready", String(status.dropFirst("Saved: ".count)))
    }
    if status.hasPrefix("No speech") {
        return ("No speech found", "Nothing to transcribe — no file was created.")
    }
    if status.hasPrefix("Downloading model") {
        return ("Transcription deferred", "The speech model is still downloading.")
    }
    if status.hasPrefix("Transcription failed") {
        return ("Transcription failed", "whisper couldn't process the segment — see the log.")
    }
    // Terminal too: an unclassified status leaves the flush flag armed to steal the next segment's push.
    if status.hasPrefix("No meeting") {
        return ("Nothing to transcribe", "No meeting overlapped this segment and it was too short to keep.")
    }
    return nil
}

/// How much longer to keep the flush spinner up before revealing the outcome. Instant outcomes
/// ("no speech" lands in ~0.3 s) must still spin visibly, or the click reads as a dead button.
func spinnerHold(elapsed: Double, minimum: Double = 1.0) -> Double {
    max(0, minimum - elapsed)
}
func printMacrecHelp() {
    print("""
    macrec \(macrecVersion) — always-on macOS meeting recorder
      Continuously records your microphone + system audio, rotates hourly, and
      transcribes the hours that contain speech locally via whisper.cpp.

    USAGE
      macrec                 launch the menu-bar app (default; continuous recording)
      macrec <command>
      macrec --out FILE.wav [options]        one-shot capture → mixed WAV

    COMMANDS
      engine                 run the continuous engine headless (no menu bar)
      config                 print resolved settings (paths, model, login item)
      perm-status            exit 0 if System Audio Recording + Microphone are granted
      request-permission     trigger the macOS permission prompts
      mic-status             exit 0 if the default input device is in use right now
      settings-snapshot [dir] render every Settings pane to a PNG (UI test kit; needs a GUI session)
      icon-snapshot [dir]     render the menu-bar brand mark (recording/voice/paused) to PNGs
      caption-snapshot [dir]  render the live caption overlay at 3 opacities (UI test kit)
      library-snapshot [dir]  render the Library window over fixture data (UI test kit)
      sweep                  run one retention/archive pass (WAV→AAC tiers) and exit
                             [--audio-dir D] [--transcripts-dir D] [--raw-days N] [--keep-days N]
      tap-probe [secs]       start only the system-audio tap, play a test tone, report whether it
                             captured (QA; exit 0 = captured, non-zero = see the verdict)
      version, --version     print the version and exit
      help,    --help        show this help

    ONE-SHOT OPTIONS (with --out)
      --duration N           stop after N seconds
      --no-mic               capture system audio only (skip the microphone)
      --exclude-app ID       exclude an app's audio by bundle id (repeatable), e.g. com.spotify.client
      --keep-temp            keep the intermediate per-source .sys/.mic WAVs

    Transcripts + audio go to the folders set in Settings (menu-bar → Settings…).
    Permissions: System Audio Recording Only + Microphone (+ Calendar for titles) — no Screen Recording.
    Docs: https://github.com/ikhoon/macrec
    """)
}

/// The app's entry logic, invoked by Cli/Entry.swift's `@main` (see CLAUDE.md for the hybrid build).
public enum App {
    // @MainActor: Cli/Entry.swift's `await App.main()` suspends, so without this runMenuBarApp() builds
    // the tray NSWindow off the main thread. (See also Task.detached in the engine stop handler below.)
    @MainActor
    public static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())

        // The test/snapshot subcommands build the real Settings pane and the real overlay, which read
        // credentials and write preferences as they go. Give them neither: no Keychain (an unsigned dev
        // build would raise an authorization prompt per read) and a throwaway defaults suite (the overlay
        // persisted its opacity and subtitle mode into the user's settings).
        if let a = args.first, ["selftest", "settings-snapshot", "icon-snapshot", "caption-snapshot",
                                "library-snapshot"].contains(a) {
            Keychain.disabled = true
            Pref.useEphemeralStoreForTest()
        }

        // Subcommands: help / version (accept the common flag spellings too).
        if let a = args.first, ["help", "--help", "-h"].contains(a) { printMacrecHelp(); exit(0) }
        if let a = args.first, ["version", "--version", "-v"].contains(a) { print("macrec \(macrecVersion)"); exit(0) }

        // Subcommand: tap-probe [seconds] — QA/diagnostic: start ONLY the system-audio tap and report
        // whether its IOProc delivers anything — built for the day capture went silent and nothing in
        // the logs could say WHERE the audio path died. The aggregate delivers NOTHING while no tapped
        // process renders audio (measured 2026-07-15: 2 s probe in silence → 0 buffers; the same probe
        // with a sound playing → 369 buffers), so the probe plays its own test tone — via CHILD afplay
        // processes, because the tap always excludes our own pid. See tapProbeVerdict for the outcomes.
        if args.first == "tap-probe" {
            if args.count > 1, Double(args[1]) == nil {
                print("tap-probe: ignoring non-numeric duration '\(args[1])' — using 6s")
            }
            let secs = max(args.count > 1 ? (Double(args[1]) ?? 6) : 6, 1)   // <1 s can't even play the tone
            let lock = NSLock()
            var buffers = 0
            var peak: Float = 0
            let tap = SystemAudioTap(excludeBundleIds: []) { buf in
                lock.lock(); defer { lock.unlock() }
                buffers += 1
                if let ch = buf.floatChannelData?[0] {
                    for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(ch[i])) }
                }
            }
            do { try tap.start() } catch { print("tap-probe: start failed — \(error)"); exit(1) }
            var tonePlayed = false
            var toneErrorShown = false
            let deadline = Date().addingTimeInterval(secs)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                if remaining < 0.2 { break }
                let play = Process()
                play.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                // -v 0.3: loud enough for the tap (captured peak ~0.1 ≫ the 0.001 silence bar), quiet
                // enough not to blast a sonar ping at whoever is next to a live call.
                play.arguments = ["-v", "0.3", "-t", String(format: "%.1f", min(remaining, 1.5)),
                                  "/System/Library/Sounds/Submarine.aiff"]
                let began = Date()
                do { try play.run() } catch {
                    print("tap-probe: could not launch afplay — \(error)")   // a diagnostic must diagnose itself
                    break
                }
                // Watchdog: a wedged afplay must not hang the probe — the audio stack is exactly what
                // this tool exists to diagnose, so assume the worst of it.
                let killer = DispatchWorkItem { if play.isRunning { play.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + min(remaining, 1.5) + 2.0, execute: killer)
                play.waitUntilExit()
                killer.cancel()
                if play.terminationStatus == 0, Date().timeIntervalSince(began) >= 0.3 {
                    tonePlayed = true
                } else {
                    if !toneErrorShown {   // first failure: say WHY the tone isn't playing, once
                        toneErrorShown = true
                        print("tap-probe: afplay exited \(play.terminationStatus) after "
                            + String(format: "%.2fs", Date().timeIntervalSince(began)))
                    }
                    Thread.sleep(forTimeInterval: 0.3)   // afplay unusable — report it, don't spin
                }
            }
            tap.stop()
            lock.lock(); let b = buffers, p = peak; lock.unlock()
            let v = tapProbeVerdict(buffers: b, peak: p, tonePlayed: tonePlayed)
            print(String(format: "tap-probe: %.1fs — buffers=%d peak=%.4f tone=%@ → %@",
                         secs, b, p, tonePlayed ? "played" : "UNPLAYABLE", v.line))
            exit(v.code)
        }

        // Subcommand: sweep — run one retention/archive pass now (WAV→AAC tiers + expiry) and exit.
        // The tray app does this on start and after each segment; this is for manual runs and the
        // integration smoke test. Saved Settings BEAT env vars everywhere in this app, so the flags
        // exist to aim a one-off sweep at an explicit layout without touching the real library.
        if args.first == "sweep" {
            var cfg = EngineConfig.load()
            var it = args.dropFirst().makeIterator()
            // A malformed value must ABORT, not silently proceed with saved settings — this command
            // irreversibly compresses/deletes whatever library the resolved config points at.
            func value(_ flag: String) -> String {
                guard let v = it.next() else { print("sweep: \(flag) needs a value"); exit(2) }
                return v
            }
            func intValue(_ flag: String) -> Int {
                let v = value(flag)
                guard let n = Int(v), n >= 0 else { print("sweep: \(flag) needs a non-negative integer, got '\(v)'"); exit(2) }
                return n
            }
            while let a = it.next() {
                switch a {
                case "--audio-dir":       cfg.audioDir = URL(fileURLWithPath: value(a))
                case "--transcripts-dir": cfg.transcriptsDir = URL(fileURLWithPath: value(a))
                case "--raw-days":        cfg.audioRawDays = intValue(a)
                case "--keep-days":       cfg.audioRetentionDays = intValue(a)
                default: print("unknown sweep option: \(a) (see: help)"); exit(2)
                }
            }
            RecordingEngine(cfg: cfg).runRetentionSweep()
            exit(0)
        }

        // Subcommand: settings-snapshot <dir> — render every Settings pane to a PNG and exit.
        // The UI test kit: LOOK at what was built. Needs a GUI session (run locally, not in CI).
        if args.first == "settings-snapshot" {
            let dir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/tmp/macrec-settings-shots")
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let wc = SettingsWindowController(onSave: {})
            let files = wc.snapshotAllPanes(to: dir)
            for f in files { print(f.path) }
            print(files.isEmpty ? "snapshot: FAILED (no panes rendered)" : "snapshot: \(files.count) panes → \(dir.path)")
            exit(files.isEmpty ? 1 : 0)
        }

        // Subcommand: library-snapshot <dir> — render the Library window over FIXTURE data to a PNG.
        // Fixture-only on purpose: a snapshot must never leak real meeting names, and the harness
        // must not read the user's vault.
        if args.first == "library-snapshot" {
            let dir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/tmp/macrec-library-shots")
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            // The fixture entries all point at this file — give the preview pane something to show.
            try? "# project kickoff\n\n- 10:30 fixture transcript for the snapshot harness\n- decisions and action items would appear here\n"
                .write(toFile: "/tmp/library-fixture.md", atomically: true, encoding: .utf8)
            LibraryWindow.shared.loadFixtureForTest(libraryFixtureDays())
            let files = LibraryWindow.shared.snapshot(to: dir)
            for f in files { print(f.path) }
            print(files.isEmpty ? "library-snapshot: FAILED (nothing rendered)" : "library-snapshot: \(files.count) shot → \(dir.path)")
            exit(files.isEmpty ? 1 : 0)
        }

        // Subcommand: caption-snapshot — render the live overlay at several opacities over a checkerboard.
        // The one thing to LOOK for: the background fades, the captions never do.
        if args.first == "caption-snapshot" {
            let dir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/tmp/macrec-caption-shots")
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            guard #available(macOS 26, *) else { print("caption-snapshot: needs macOS 26"); exit(1) }
            // Both presentations, at both extremes: the log view and the subtitle view have different
            // failure modes, and the transparent end is the one that used to hide the captions entirely.
            // Writing the pref is safe — Pref.d is a throwaway suite under any test subcommand.
            var files: [URL] = []
            for subtitle in [false, true] {
                Pref.d.set(subtitle, forKey: Pref.liveSubtitle)
                let w = LiveCaptionWindow(onClose: {}, onReconfigure: {}, onRestyle: {})
                let sub = dir.appendingPathComponent(subtitle ? "subtitle" : "log")
                files += w.snapshotOpacities([1.0, 0.6, 0.0], to: sub)
            }
            for f in files { print(f.path) }
            if files.isEmpty {
                print("caption-snapshot: FAILED — the overlay rendered to nothing, so no PNG was written. "
                    + "Something in the panel is composited by the window server again (a vibrancy material, "
                    + "or the .hudWindow style mask); an offscreen render cannot see those.")
            } else {
                print("caption-snapshot: \(files.count) shots → \(dir.path)")
            }
            exit(files.isEmpty ? 1 : 0)
        }

        // Subcommand: icon-snapshot — render the menu-bar brand mark's states to PNGs on a gray backdrop
        // (the tray icon has no other snapshot; UI test kit per CLAUDE.md). LOOK at these after any change.
        if args.first == "icon-snapshot" {
            let dir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/tmp/macrec-icon-shots")
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.accessory)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let states: [(String, Bool, Bool)] = [("recording-voice", true, true), ("recording-quiet", true, false), ("paused", false, false)]
            let side: CGFloat = 18, scale = 10, pad: CGFloat = 6
            var wrote = 0
            for (name, rec, voice) in states {
                let mark = brandMarkImage(side: side, recording: rec, voice: voice)
                let w = mark.size.width + pad * 2, h = mark.size.height + pad * 2   // fit the glyph's natural aspect
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w) * scale, pixelsHigh: Int(h) * scale,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                rep.size = NSSize(width: w, height: h)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor(white: 0.16, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()   // menu-bar-ish backdrop
                mark.draw(in: NSRect(x: pad, y: pad, width: mark.size.width, height: mark.size.height))
                NSGraphicsContext.restoreGraphicsState()
                if let png = rep.representation(using: .png, properties: [:]) {
                    let u = dir.appendingPathComponent("icon-\(name).png"); try? png.write(to: u); print(u.path); wrote += 1
                }
            }
            print(wrote == 0 ? "icon-snapshot: FAILED" : "icon-snapshot: \(wrote) states → \(dir.path)")
            exit(wrote == 0 ? 1 : 0)
        }

        // Subcommand: selftest — assertions on pure logic (run in CI). No GUI/permissions needed.
        if args.first == "selftest" { runSelftest() }

        // Subcommand: mic-status — is the default input device currently in use?
        if args.first == "mic-status" {
            print(micStatus() ? "1" : "0")
            exit(0)
        }

        // Subcommand: config — print the loaded settings (UserDefaults > env > default) and exit.
        if args.first == "config" {
            let c = EngineConfig.load()
            print("suite=\(Pref.suiteName)")
            print("segmentSeconds=\(Int(c.segmentSeconds)) voiceMin=\(Int(c.voiceMinSeconds)) lang=\(c.whisperLang) vad=\(c.vadEnabled) keepAudio=\(c.keepAudio) audioRawDays=\(c.audioRawDays) audioRetDays=\(c.audioRetentionDays) txtRetDays=\(c.transcriptRetentionDays)")
            print("exclude=\(c.excludeBundleIds) transcriptsDir=\(c.transcriptsDir.path)")
            print("model=\(WhisperCatalog.selected.name) ready=\(ModelStore.shared.isReady)")
            print("whisperCli=\(c.whisperCli)")
            print("whisperModel=\(c.whisperModel)")
            print("vadModel=\(c.vadModel)")
            if #available(macOS 13, *) {
                print("loginItem=\(LoginItem.managedByLaunchAgent ? "managed-by-launchagent" : "\(LoginItem.status)")")
            }
            exit(0)
        }

        // Subcommand: perm-status — are System Audio Recording + Microphone granted? (no prompt)
        if args.first == "perm-status" {
            let ok = audioCaptureAuthorized() && micAuthorized()
            print(ok ? "1" : "0")
            exit(ok ? 0 : 1)
        }

        // Subcommand: request-permission — prompt for / register both permissions. Never hangs.
        if args.first == "request-permission" {
            let p = requestPermissions()
            elog("system-audio=\(p.audio) microphone=\(p.mic)")
            print(p.audio && p.mic ? "1" : "0")
            exit(p.audio && p.mic ? 0 : 3)
        }

        // Subcommand: register — force this binary into the TCC lists by actually creating a Core
        // Audio process tap (first tap creation triggers the "System Audio Recording Only" prompt)
        // + firing the mic prompt. A watchdog exits so a not-yet-granted create can't hang forever.
        if args.first == "register" {
            _ = requestPermissions()   // TCCAccessRequest(kTCCServiceAudioCapture) + mic prompt
            DispatchQueue.global().asyncAfter(deadline: .now() + 25) { exit(0) }  // watchdog (keep prompt alive)
            let probe = SystemAudioTap(excludeBundleIds: []) { _ in }
            do { try probe.start(); try? await Task.sleep(nanoseconds: 2_000_000_000); probe.stop() }
            catch { elog("register attempt: \(error)") }
            exit(0)
        }

        // Subcommand: engine — continuous capture, hourly rotation, mic-gated transcription (headless).
        if args.first == "engine" {
            ModelStore.shared.ensure()   // first-run model download (headless; progress goes to the log)
            let engine = RecordingEngine(cfg: EngineConfig.load())
            do { try await engine.start() } catch { elog("engine: \(error)"); exit(3) }
            installStopHandler {
                let s = DispatchSemaphore(value: 0)
                // Task.detached, NOT Task {}: main() is @MainActor, so a plain Task would inherit the
                // main actor and never run — the main thread is parked on the wait() below. Detached
                // runs engine.stop() on the global executor so s.signal() actually fires.
                Task.detached { await engine.stop(); s.signal() }
                _ = s.wait(timeout: .now() + 20)
                exit(0)
            }
            // Keep the process alive. The rotation timer and signal handler run on their own
            // dispatch queues; dispatchMain() doesn't hold under an async @main, so block here.
            DispatchSemaphore(value: 0).wait()
        }

        // No CLI subcommand and no --out → launch the menu-bar app (this is how the .app starts).
        if args.isEmpty || args.first == "app" {
            runMenuBarApp()   // never returns (NSApp.run)
        }

        var outPath: String?
        var noMic = false
        var keepTemp = false
        var duration: Double?
        var excludeBundleIds: [String] = []   // app bundle ids to exclude from the audio (e.g. Spotify)
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--out": i += 1; if i < args.count { outPath = args[i] }
            case "--no-mic": noMic = true
            case "--keep-temp": keepTemp = true
            case "--duration": i += 1; if i < args.count { duration = Double(args[i]) }
            case "--exclude-app": i += 1; if i < args.count { excludeBundleIds.append(args[i]) }
            default: elog("unknown arg: \(args[i])")
            }
            i += 1
        }

        guard let outPath = outPath else {
            elog("error: --out <path.wav> is required")
            exit(2)
        }

        let outURL = URL(fileURLWithPath: outPath)
        let base = outURL.deletingPathExtension().path
        let sysURL = URL(fileURLWithPath: base + ".sys.wav")
        let micURL = URL(fileURLWithPath: base + ".mic.wav")

        // Preflight permissions. Creating the tap without System Audio Recording permission would
        // fail; under a background launchd agent no prompt can show, so bail out early.
        guard audioCaptureAuthorized() else {
            elog("error: System Audio Recording permission not granted. Run `macrec request-permission`, then enable macrec in System Settings → Privacy & Security → System Audio Recording Only.")
            _ = requestPermissions()
            exit(3)
        }
        guard noMic || micAuthorized() else {
            elog("error: Microphone permission not granted. Run `macrec request-permission`, then enable macrec in System Settings → Microphone.")
            _ = requestPermissions()
            exit(3)
        }

        do {
            let rec = Recorder(sysWriter: try SourceWriter(url: sysURL),
                               micWriter: noMic ? nil : try SourceWriter(url: micURL))

            // System audio via a Core Audio process tap (excludes our own PID + the given bundle ids,
            // e.g. Spotify). Mic on a separate AVCaptureSession, as in the continuous engine.
            let tap = SystemAudioTap(excludeBundleIds: excludeBundleIds) { [rec] buf in rec.appendSys(buf) }
            let micCap = MicCapture()

            // Stop coordination via semaphore + signal sources.
            let sem = DispatchSemaphore(value: 0)
            let sigQ = DispatchQueue(label: "macrec.signal")
            for s in [SIGINT, SIGTERM] {
                signal(s, SIG_IGN)
                let src = DispatchSource.makeSignalSource(signal: s, queue: sigQ)
                src.setEventHandler { sem.signal() }
                src.resume()
                signalSources.append(src)
            }

            try tap.start()
            if !noMic {
                do { try micCap.start(into: rec) }
                catch { elog("macrec: mic capture failed: \(error)") }
            }
            elog("macrec: recording → \(outPath)  (mic=\(!noMic))")
            if let duration = duration {
                sigQ.asyncAfter(deadline: .now() + duration) { sem.signal() }
            }

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    sem.wait()
                    cont.resume()
                }
            }

            elog("macrec: stopping…")
            micCap.stop()
            tap.stop()
            rec.finalizeWriters()  // flush WAV headers before we read them back

            try mixDown(sysURL: sysURL, micURL: noMic ? nil : micURL, outURL: outURL)
            if !keepTemp {
                try? FileManager.default.removeItem(at: sysURL)
                if !noMic { try? FileManager.default.removeItem(at: micURL) }
            }

            elog("macrec: done → \(outPath)")
            print(outPath)  // stdout = final mixed file path
            exit(0)
        } catch {
            elog("macrec error: \(error)")
            try? FileManager.default.removeItem(at: sysURL)
            try? FileManager.default.removeItem(at: micURL)
            exit(1)
        }
    }
}
