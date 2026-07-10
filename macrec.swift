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

/// Minimal Keychain string store for long-lived credentials (generic passwords under this app's service).
enum Keychain {
    /// One SecItem read per account per process. `LiveEngine.isReady` is consulted from menu building,
    /// pane building, the overlay's control bar and every Save — each read is an authorization check, and
    /// an unsigned build (a bare `swiftc` binary) turns each one into a password prompt.
    private static let lock = NSLock()
    private static var cache: [String: String?] = [:]
    private static var secretRequests = 0

    /// Set by the CLI subcommands that must never touch the user's real credentials (selftest, snapshots).
    nonisolated(unsafe) static var disabled = false

    /// Every request for a SECRET, cached or not. Asking for a secret is what raises the authorization
    /// prompt; asking whether one exists does not. Code that only needs presence must use `exists`.
    static var secretRequestsForTest: Int { lock.lock(); defer { lock.unlock() }; return secretRequests }
    static func forgetCacheForTest() { lock.lock(); cache.removeAll(); lock.unlock() }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.ikhoon.macrec",
         kSecAttrAccount as String: account]
    }

    /// Is a credential stored? An attributes-only query never hands the secret back, so it never asks the
    /// user to authorize anything.
    static func exists(_ account: String) -> Bool {
        if disabled { return false }
        lock.lock()
        if let hit = cache[account] { lock.unlock(); return hit != nil }
        lock.unlock()
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status != errSecSuccess, status != errSecItemNotFound { elog("keychain: probe '\(account)' failed (\(status))") }
        return status == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        lock.lock(); secretRequests += 1; lock.unlock()
        if disabled { return nil }
        lock.lock()
        if let hit = cache[account] { lock.unlock(); return hit }
        lock.unlock()
        let value = read(account)
        lock.lock(); cache[account] = value; lock.unlock()
        return value
    }
    private static func read(_ account: String) -> String? {
        lock.lock(); reads += 1; lock.unlock()
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status != errSecSuccess {
            // Absent is normal; anything else is a real Keychain problem — don't disguise it as "no key".
            if status != errSecItemNotFound { elog("keychain: read '\(account)' failed (\(status))") }
            return nil
        }
        guard let d = out as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }
    /// Empty value deletes the item. A non-empty value RECREATES it: macOS binds an item's access
    /// control list to the process that created it, and `SecItemUpdate` never refreshes that list — so
    /// an item created once by the wrong binary keeps asking the user to authorize the right one,
    /// forever. Deleting and re-adding rebinds the ACL to the app doing the save.
    ///
    /// The old update-then-add order guarded against a failed add dropping the credential. We hold
    /// `value` throughout, so a failed add is retried and then reported — it is never silently lost.
    /// Returns whether the operation actually succeeded (callers migrating data must check).
    @discardableResult
    static func set(_ account: String, _ value: String) -> Bool {
        if disabled { return true }
        func remember(_ v: String?) { lock.lock(); cache[account] = v; lock.unlock() }
        func delete() -> OSStatus { SecItemDelete(query(account) as CFDictionary) }

        guard !value.isEmpty else {
            let status = delete()
            if status != errSecSuccess && status != errSecItemNotFound { elog("keychain: delete '\(account)' failed (\(status))"); return false }
            remember(nil)
            return true
        }
        let status = delete()
        if status != errSecSuccess && status != errSecItemNotFound {
            elog("keychain: could not clear '\(account)' before rewriting it (\(status))"); return false
        }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        // Credential stays on THIS machine (no backup/migration restore) but is readable after login.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var add = SecItemAdd(q as CFDictionary, nil)
        if add != errSecSuccess {
            elog("keychain: add '\(account)' failed (\(add)) — retrying once")
            add = SecItemAdd(q as CFDictionary, nil)
        }
        if add != errSecSuccess {
            elog("keychain: save '\(account)' failed (\(add)); the previous value was removed and NOT restored")
            remember(nil)
            return false
        }
        remember(value)
        return true
    }

    /// Reads that actually reached the Keychain this process. A flood of authorization prompts is a
    /// caching bug, not a Keychain quirk.
    static var readsForTest: Int { lock.lock(); defer { lock.unlock() }; return reads }
    private static var reads = 0
}

func elog(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
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

enum Pref {
    // Dedicated suite (MUST differ from the bundle id — suiteName==bundleID returns nil / doesn't work).
    // Works around .standard domain not resolving when launchd execs the binary inside the .app directly.
    // To inspect from the CLI: `defaults read com.ikhoon.macrec.prefs`
    static let suiteName = "com.ikhoon.macrec.prefs"
    static let d = UserDefaults(suiteName: suiteName) ?? .standard
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

struct CompletedSegment {
    let start: Date
    let sysURL: URL
    let micURL: URL
    let micVoicedSeconds: Double
    let sysVoicedSeconds: Double
    let micSpeechSeconds: Double   // voiced time inside sustained (>=50 ms) runs — clicks contribute ~0
    let sysSpeechSeconds: Double
    let sysPeak: Float
    let micPeak: Float
    let durationSeconds: Double
    /// Either side speaking is worth transcribing (covers listen-only meetings where only sys speaks).
    var voicedSeconds: Double { max(micVoicedSeconds, sysVoicedSeconds) }
    var speechSeconds: Double { max(micSpeechSeconds, sysSpeechSeconds) }   // sustained speech only (clicks ≈ 0)
}

func segFormatter() -> DateFormatter {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd-HHmmss"; return f
}

// MARK: - system-audio capture (Core Audio process tap — "System Audio Recording Only")

/// Captures the system audio mix via a Core Audio process tap + private aggregate device (macOS
/// 14.4+). Needs only kTCCServiceAudioCapture — no Screen Recording, no orange dot. Excludes our
/// own process (and any excluded apps, e.g. Spotify) so we don't record ourselves / that app.
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
        // stereoGlobalTapButExcludeProcesses = the whole system mix minus these processes; a global
        // tap is unmuted by default (audio stays audible), which is exactly what we want.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        desc.uuid = UUID(); desc.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        var st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr, tap != kAudioObjectUnknown else { throw Self.err("create tap", st) }
        tapID = tap
        guard let fmt = Self.tapFormat(tap) else { stop(); throw Self.err("tap format", -1) }
        format = fmt

        let outUID = outputDeviceUID(defaultOutputDeviceID())
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "macrec-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outUID as Any,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID as Any]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        st = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard st == noErr, agg != kAudioObjectUnknown else { stop(); throw Self.err("create aggregate", st) }
        aggID = agg

        st = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, ioQueue) { [weak self] _, inData, _, _, _ in
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
        guard st == noErr, let p = procID else { stop(); throw Self.err("create IOProc", st) }
        st = AudioDeviceStart(aggID, p)
        guard st == noErr else { stop(); throw Self.err("device start", st) }
        elog("engine: system-audio tap started (\(Int(fmt.sampleRate))Hz \(fmt.channelCount)ch, excluding \(exclude.count) procs)")
    }

    func stop() {
        if aggID != kAudioObjectUnknown, let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
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
        var cf: CFString? = nil
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
final class CaptureSession {
    private var tap: SystemAudioTap?
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
            return
        }
        let t = SystemAudioTap(excludeBundleIds: excludeBundleIds) { [weak self] buf in self?.rec.appendSys(buf) }
        try t.start()
        tap = t
    }

    /// Rebuild the tap + mic (e.g. resuming after sleep/wake). Keeps the current writers running.
    func restartStream() async -> Bool {
        tap?.stop(); tap = nil
        do { try startTap(); try mic.start(into: rec); return true }
        catch { elog("engine: tap restart failed: \(error)"); return false }
    }

    /// An excluded app that launches (or relaunches with a new pid) AFTER the tap was created is not
    /// excluded by it — `CATapDescription` freezes a set of process object IDs. Rebuild the tap only
    /// when the set it should exclude has actually drifted, so an unrelated app launching costs nothing.
    func refreshExclusionsIfStale() async {
        guard let live = tap else { return }
        let current = matchExcludedProcesses(SystemAudioTap.audioProcesses(), excludeBundleIds: excludeBundleIds)
        guard tapExclusionIsStale(current: current, live: live.matchedExclusions) else { return }
        elog("engine: exclusion set changed (\(live.matchedExclusions.count) → \(current.count)) — rebuilding the tap")
        _ = await restartStream()
    }

    /// Pause capture (mic + system tap) on lock/sleep.
    func suspendStream() async {
        mic.stop()
        tap?.stop(); tap = nil
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

/// A calendar event reduced to what titling a recorded segment depends on — a pure stand-in for
/// `EKEvent` so the choice below is directly testable.
struct EventCandidate: Equatable {
    let title: String
    let start: Date
    let end: Date
    let hasLink: Bool   // a Zoom/Meet/Teams/Webex URL sits somewhere on the event
}

/// Seconds of the recorded segment `[segStart, segEnd]` the event actually covers.
func eventOverlap(_ e: EventCandidate, segStart: Date, segEnd: Date) -> TimeInterval {
    max(0, min(e.end, segEnd).timeIntervalSince(max(e.start, segStart)))
}

/// Can this event plausibly be what the segment recorded? It must overlap at least HALF of whichever
/// is shorter — itself, or the segment. Any positive overlap used to qualify, so the next meeting
/// bleeding two minutes into a 62-minute recording could title the whole thing. Half-of-the-shorter
/// still admits a one-minute tail that lies wholly inside a 90-minute meeting: that IS the meeting.
func explainsSegment(_ e: EventCandidate, segStart: Date, segEnd: Date) -> Bool {
    let ov = eventOverlap(e, segStart: segStart, segEnd: segEnd)
    guard ov > 0 else { return false }   // caught only by the ±padding: it belongs to a neighbour
    let shorter = min(e.end.timeIntervalSince(e.start), segEnd.timeIntervalSince(segStart))
    return ov * 2 >= shorter
}

/// Index of the event that best titles a recorded segment. Among the events that could plausibly BE
/// the segment, a meeting link decides: it separates a real online meeting from the all-day offsite
/// and the personal blocks sitting on top of it — a 32-minute "Service Mesh Weekly Sync" should win
/// over a 58-minute "인버터". Raw overlap cannot make that call, which is why the eligibility floor,
/// not the ordering, is what keeps a 2-minute sliver from stealing the name. Pure + selftested.
func bestEventIndex(segStart: Date, segEnd: Date, candidates: [EventCandidate]) -> Int? {
    func ov(_ e: EventCandidate) -> TimeInterval { eventOverlap(e, segStart: segStart, segEnd: segEnd) }
    return candidates.indices
        .filter { explainsSegment(candidates[$0], segStart: segStart, segEnd: segEnd) }
        .sorted { i, j in
            let a = candidates[i], b = candidates[j]
            if a.hasLink != b.hasLink { return a.hasLink }     // an online meeting beats a calendar block
            if ov(a) != ov(b) { return ov(a) > ov(b) }         // then the one that fills the segment
            if a.start != b.start { return a.start < b.start } // still tied → earliest, then by title,
            return a.title < b.title                           // so the pick never depends on EK order
        }
        .first
}

// MARK: - calendar lookup (title a transcript from the overlapping event)

enum CalendarLookup {
    static let store = EKEventStore()

    static var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Trigger the one-time Calendar permission prompt (no-op if already decided).
    static func requestAccess() {
        store.requestFullAccessToEvents { ok, err in
            if let err = err { elog("calendar access: \(err)") } else { elog("calendar access granted=\(ok)") }
        }
    }

    /// `start` is the EVENT's start (not the segment's) — a transcript stamps itself with the meeting's
    /// time when one maps. See `transcriptStart`.
    struct Match { let title: String; let link: String?; let attendees: [String]; let start: Date }

    /// The event calendars the user chose to source titles from (by title). Empty selection — or a
    /// selection that matches nothing (e.g. a renamed calendar) — means "all calendars" (nil).
    static var selectedCalendars: [EKCalendar]? {
        let names = (Pref.d.stringArray(forKey: Pref.calendars) ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        let want = Set(names)
        let cals = store.calendars(for: .event).filter { want.contains($0.title) }
        return cals.isEmpty ? nil : cals
    }

    /// Titles of all available event calendars (deduped, sorted) — for the Settings picker.
    static func availableCalendarNames() -> [String] {
        guard authorized else { return [] }
        return Array(Set(store.calendars(for: .event).map { $0.title })).sorted()
    }

    /// Calendars with the color the user assigned them in Calendar.app, so the picker reads like the
    /// calendar they already know. `EKCalendar.color` is normalized to sRGB before use — a calendar can
    /// carry a color in another space, and the components are only meaningful once converted (same
    /// approach as maccal's `hexColor`). Deduped by title (first color wins), sorted by title.
    static func availableCalendars() -> [(name: String, color: NSColor)] {
        guard authorized else { return [] }
        var byName: [String: NSColor] = [:]
        for c in store.calendars(for: .event) where byName[c.title] == nil {
            byName[c.title] = c.color?.usingColorSpace(.sRGB) ?? .secondaryLabelColor
        }
        return byName.keys.sorted().map { ($0, byName[$0]!) }
    }

    /// Best event overlapping [start, end] — the one that fills most of it (see `bestEventIndex`).
    static func match(start: Date, end: Date) -> Match? {
        guard authorized else { return nil }
        let pred = store.predicateForEvents(withStart: start.addingTimeInterval(-300), end: end.addingTimeInterval(60), calendars: selectedCalendars)
        let events = store.events(matching: pred).filter { !$0.isAllDay && !($0.title ?? "").isEmpty }
        guard !events.isEmpty else { return nil }

        func link(_ e: EKEvent) -> String? {
            let hay = [e.location, e.notes, e.url?.absoluteString].compactMap { $0 }.joined(separator: "\n")
            let pats = ["zoom.us/j/", "zoom.us/my/", "zoom.us/s/", "meet.google.com/", "teams.microsoft.com/", "webex.com/"]
            for tok in hay.split(whereSeparator: { " \n\t\r<>\"'(),".contains($0) }) {
                let s = String(tok)
                if pats.contains(where: { s.lowercased().contains($0) }) { return s }
            }
            return nil
        }

        // An event caught only by the ±padding has zero true overlap: it belongs to the NEXT segment, and
        // since the event's start stamps the file name, keeping it makes two segments collide.
        let candidates = events.map {
            EventCandidate(title: $0.title, start: $0.startDate, end: $0.endDate, hasLink: link($0) != nil)
        }
        guard let i = bestEventIndex(segStart: start, segEnd: end, candidates: candidates) else { return nil }
        let chosen = events[i]
        let names = (chosen.attendees ?? []).compactMap { $0.name }.filter { !$0.isEmpty }
        return Match(title: chosen.title, link: link(chosen), attendees: names, start: chosen.startDate)
    }
}

// MARK: - transcriber (per-track whisper-cli → speaker-labeled, time-merged transcript)

enum Transcriber {
    /// Run whisper-cli (VAD + suppress-non-speech) on a 16kHz/16-bit WAV; return its timestamped stdout.
    private static func runWhisper(_ wav16: URL, _ cfg: EngineConfig, hints: String = "") -> String {
        guard FileManager.default.isExecutableFile(atPath: cfg.whisperCli),
              FileManager.default.fileExists(atPath: cfg.whisperModel) else {
            elog("transcribe: whisper-cli or model missing (\(cfg.whisperCli))"); return ""
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cfg.whisperCli)
        var args = ["-m", cfg.whisperModel, "-f", wav16.path, "-l", cfg.whisperLang, "-np", "-sns",
                    // Anti-hallucination (whisper.cpp #2286, openai/whisper #679): killing the
                    // rolling text context stops a degenerate window from feeding the NEXT window's
                    // prompt — the self-reinforcing repetition loop that junked whole hours of
                    // broadcast/BGM audio. Raised entropy/logprob thresholds make the decoder retry
                    // at higher temperature instead of accepting low-entropy loop output; the
                    // temperature fallback itself stays ON — it is the escape hatch.
                    "--entropy-thold", "2.6", "--logprob-thold", "-1.25"]
        if hints.isEmpty {
            args += ["--max-context", "0"]
        } else {
            // whisper-cli gates ALL prompt injection on max-context > 0, so a flat 0 would silently
            // kill the hints. Instead: carry the hints into EVERY window (an upgrade — previously
            // they only biased the first ~30s) and size max-context to roughly the hint tokens, so
            // the rolling-context budget left over for loop-feeding stays ~0.
            let hintTokens = min(224, max(16, hints.utf8.count / 3))
            args += ["--carry-initial-prompt", "--max-context", String(hintTokens)]
        }
        if cfg.vadEnabled && FileManager.default.fileExists(atPath: cfg.vadModel) {
            // Tightened VAD: the default threshold (0.5) passed sung vocals into the decoder and
            // one-burst noises (a cough) transcribed to a word. Longer min-durations drop those;
            // generous padding keeps soft sentence tails.
            args += ["--vad", "--vad-model", cfg.vadModel,
                     "--vad-threshold", "0.55",
                     "--vad-min-speech-duration-ms", "300",
                     "--vad-min-silence-duration-ms", "300",
                     "--vad-speech-pad-ms", "150"]
        }
        if !hints.isEmpty { args += ["--prompt", hints] }   // proper-noun dictionary biases decoding
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { elog("whisper run: \(error)"); return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Parse "[HH:MM:SS.mmm --> ...]  text" lines into (startSeconds, text).
    private static func parse(_ output: String) -> [(Double, String)] {
        var segs: [(Double, String)] = []
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            guard line.hasPrefix("["), let arrow = line.range(of: " --> "), let close = line.range(of: "]") else { continue }
            let ts = line[line.index(after: line.startIndex)..<arrow.lowerBound].split(separator: ":")
            guard ts.count == 3, let h = Double(ts[0]), let m = Double(ts[1]), let s = Double(ts[2]) else { continue }
            let text = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { segs.append((h * 3600 + m * 60 + s, text)) }
        }
        return segs
    }

    // MARK: hallucination scrubbing — whisper fabricates fluent text on music/noise/silence
    // (its training data paired non-speech audio with video credits), and a degenerate window can
    // loop one sentence for many minutes. These pure detectors run per TRACK before the merge.

    /// YouTube-outro boilerplate whisper hallucinates on non-speech — seen VERBATIM in our junk
    /// transcripts (ご視聴ありがとうございました on a quiet living-room hour, etc.).
    static let hallucinationBoilerplate = [
        "시청해 주셔서 감사합니다", "시청해주셔서 감사합니다", "구독과 좋아요", "다음 영상에서 만나",
        "thank you for watching", "thanks for watching", "ご視聴ありがとうございました",
    ]

    /// Within-line degeneration: "oh, oh, oh, oh…" compresses absurdly well. Ratio of raw UTF-8
    /// size to compressed size; real sentences land ~1.0–1.5, loops blow past 2.4. Apple's
    /// COMPRESSION_ZLIB emits raw DEFLATE (no 2-byte header/4-byte adler) — the +6 keeps the ratio
    /// calibrated to the zlib-framed implementation the 2.4 threshold comes from (openai/whisper).
    static func compressionRatio(_ s: String) -> Double {
        let src = Array(s.utf8)
        guard src.count > 0 else { return 1 }
        var dst = [UInt8](repeating: 0, count: src.count + 1024)
        let n = compression_encode_buffer(&dst, dst.count, src, src.count, nil, COMPRESSION_ZLIB)
        guard n > 0 else { return 1 }
        return Double(src.count) / Double(n + 6)
    }

    /// Share of the most frequent word 4-gram — a loop shows one 4-gram dominating. Only
    /// meaningful with ≥20 grams (≥23 words); shorter lines return 0.
    static func maxNgramShare(_ s: String, n: Int = 4) -> Double {
        let words = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= n + 19 else { return 0 }
        var counts: [String: Int] = [:]
        for i in 0...(words.count - n) { counts[words[i..<(i + n)].joined(separator: " "), default: 0] += 1 }
        return Double(counts.values.max() ?? 0) / Double(words.count - n + 1)
    }

    static func isHallucinatedLine(_ text: String) -> Bool {
        // Boilerplate must BE the line (± a little punctuation), not merely appear in it — a real
        // sentence that *mentions* a boilerplate phrase (an A/B-test discussion, a demo ending with
        // "thank you for watching the demo…") must survive.
        let t = text.lowercased()
        if hallucinationBoilerplate.contains(where: { t.contains($0.lowercased()) && text.count <= $0.count + 10 }) {
            return true
        }
        // The 80-byte gate keeps short real repetition alive (backchannels, chants) —
        // per-line ratios on tiny strings are noisy, and sub-80-byte junk is cheap collateral.
        if text.utf8.count > 80, compressionRatio(text) > 2.4 { return true }
        // A phrase-loop's max share ≈ 1/period — 0.1 catches periods ≤ 9 words; longer-period
        // loops compress well and are caught by the ratio check above instead.
        if maxNgramShare(text) > 0.1 { return true }
        return false
    }

    /// Drop hallucinated lines and COLLAPSE identical-line runs (the minutes-long loop that
    /// repeats one sentence hundreds of times keeps its first occurrence only). The 30 s gap guard
    /// keeps REAL repeats: two identical backchannels half an hour apart are both kept — loop
    /// lines arrive seconds apart, so every link in the chain stays inside the window.
    static func scrubLines(_ lines: [(Double, String)]) -> (kept: [(Double, String)], dropped: Int) {
        var kept: [(Double, String)] = []
        var dropped = 0
        var prevText = ""
        var prevTime = -1e9
        for l in lines {
            defer { prevText = l.1; prevTime = l.0 }
            if isHallucinatedLine(l.1) { dropped += 1; continue }
            if l.1 == prevText, l.0 - prevTime < 30 { dropped += 1; continue }
            kept.append(l)
        }
        return (kept, dropped)
    }

    /// Convert a float32 WAV to 16kHz/16-bit (what whisper-cli expects). Returns the temp file URL.
    private static func convert16(_ src: URL) -> URL? {
        do {
            let inFile = try AVAudioFile(forReading: src)
            guard inFile.length > 0 else { return nil }
            let outURL = URL(fileURLWithPath: src.deletingPathExtension().path + ".16.wav")
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            let outFile = try AVAudioFile(forWriting: outURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let block: AVAudioFrameCount = 16000
            while inFile.framePosition < inFile.length {
                guard let buf = AVAudioPCMBuffer(pcmFormat: canon, frameCapacity: block) else { break }
                try inFile.read(into: buf, frameCount: block)
                if buf.frameLength == 0 { break }
                try outFile.write(from: buf)
            }
            return outURL
        } catch { elog("convert16(\(src.lastPathComponent)): \(error)"); return nil }
    }

    /// Transcribe mic ("me") and system ("them") SEPARATELY, then merge by time into a speaker-labeled
    /// transcript. Mixes a kept WAV only when keepAudio. Returns (mixedWav?, text).
    static func transcribe(_ seg: CompletedSegment, cfg: EngineConfig) -> (mixed: URL?, text: String)? {
        var mixed: URL? = nil
        if cfg.keepAudio {
            let stem = URL(fileURLWithPath: seg.sysURL.path).deletingPathExtension().deletingPathExtension()
            let m = URL(fileURLWithPath: stem.path + ".wav")
            do { try mixDown(sysURL: seg.sysURL, micURL: seg.micURL, outURL: m); mixed = m }
            catch { elog("mixdown: \(error)") }
        }
        // Speaker labels follow the transcription language (auto → the system language).
        let lang = cfg.whisperLang == "auto" ? Locale.current.language.languageCode?.identifier : cfg.whisperLang
        let (mine, theirs) = speakerLabels(forLanguage: lang)
        let hints = transcriptionHints(start: seg.start, end: seg.start.addingTimeInterval(seg.durationSeconds))
        if !hints.isEmpty { elog("transcribe: hints (\(hints.split(separator: ",").count) terms)") }
        var merged: [(start: Double, who: String, text: String)] = []
        var scrubbed = 0
        if let mic16 = convert16(seg.micURL) {
            let (kept, dropped) = scrubLines(parse(runWhisper(mic16, cfg, hints: hints)))
            merged += kept.map { (start: $0.0, who: mine, text: $0.1) }
            scrubbed += dropped
            try? FileManager.default.removeItem(at: mic16)
        }
        if let sys16 = convert16(seg.sysURL) {
            let (kept, dropped) = scrubLines(parse(runWhisper(sys16, cfg, hints: hints)))
            merged += kept.map { (start: $0.0, who: theirs, text: $0.1) }
            scrubbed += dropped
            try? FileManager.default.removeItem(at: sys16)
        }
        if scrubbed > 0 { elog("transcribe: scrubbed \(scrubbed) hallucinated/looping lines") }
        merged.sort { $0.start < $1.start }
        // Belt to the AEC's braces: the residual the canceller leaves still transcribes — drop mic
        // lines that are (garbled) copies of a nearby far-end line (see suppressEchoLines).
        if EchoCanceller.shared.enabled {
            let before = merged.count
            merged = suppressEchoLines(merged, mine: mine)
            if merged.count != before { elog("transcribe: suppressed \(before - merged.count) echo line(s)") }
        }
        let tf = DateFormatter(); tf.locale = Locale(identifier: "en_US_POSIX"); tf.dateFormat = "HH:mm:ss"
        let text = merged.map { "[\(tf.string(from: seg.start.addingTimeInterval($0.start)))] \($0.who): \($0.text)" }
            .joined(separator: "\n")
        return (mixed, text)
    }
}

// MARK: - recording engine (continuous, hourly rotation, mic-gated transcription)

final class RecordingEngine {
    let cfg: EngineConfig
    let session: CaptureSession
    private let timerQueue = DispatchQueue(label: "macrec.timer")
    private let processQueue = DispatchQueue(label: "macrec.process")  // serial: transcribe one at a time
    private var timer: DispatchSourceTimer?
    private(set) var running = false
    private var recovering = false
    private var suspended = false   // true while the display/system is asleep
    private var exclusionRefresh: DispatchWorkItem?   // debounces the app-launch exclusion re-scan
    private var warnedDeadMic = false            // one dead-mic push per engine run (not per hour)
    var onTranscriptSaved: ((String) -> Void)?   // (message) — for refreshing UI state
    var onTranscriptURL: ((URL) -> Void)?        // path of the saved transcript file — notification click → open file
    var onSegmentResult: ((String) -> Void)?      // (message) — notify even when dropped for no speech

    init(cfg: EngineConfig) {
        self.cfg = cfg
        self.session = CaptureSession(excludeBundleIds: cfg.excludeBundleIds, workDir: cfg.workDir)
    }

    /// Cut what's recorded so far and transcribe/save it immediately, without waiting for the on-the-hour rotation (tray "Transcribe now").
    func flushNow() {
        guard running, let seg = session.rotate() else { return }
        processQueue.async { self.process(seg) }
    }

    /// On sleep: stop the system-audio stream so we don't hold the display/audio while it powers down.
    private func suspendForSleep() {
        guard running, !suspended else { return }
        suspended = true
        elog("engine: lock/sleep → suspending capture (mic + system)")
        onSegmentResult?("Paused (locked/asleep)")
        Task { await session.suspendStream() }
    }

    /// On unlock/wake: clear suspension and rebuild the stream.
    private func wake() {
        guard running else { return }
        suspended = false
        elog("engine: unlock/wake → resuming capture")
        onSegmentResult?("Recording · mic + system audio")
        recover()
    }

    /// Current per-source input level (0..1) for the live menu meter — is audio coming in right now?
    func liveLevels() -> (mic: Float, sys: Float) {
        guard running else { return (0, 0) }
        // Writers are swapped/released ON rec.queue at every rotation; reading the refs off-queue
        // races that swap (review finding: the 1 Hz voice poll could catch the old writer's final
        // release → over-release). Snapshot on the queue — its work items are short buffer appends,
        // and nothing on rec.queue ever syncs back to main, so this can't deadlock.
        let rec = session.rec
        return rec.queue.sync { (rec.micWriter?.recentLevel ?? 0, rec.sysWriter?.recentLevel ?? 0) }
    }

    /// Coalesce a burst of launch/quit notifications into one exclusion re-scan.
    private func scheduleExclusionRefresh() {
        exclusionRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running, !self.suspended else { return }
            Task { await self.session.refreshExclusionsIfStale() }
        }
        exclusionRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// A tap created before "System Audio Recording Only" was granted delivers muted (zero) buffers.
    /// Poll the grant for a few minutes; the moment it flips to authorized, rebuild the tap so real
    /// system audio starts flowing — no manual Resume needed after the user clicks Allow.
    func waitForAudioGrantThenRestart() {
        Task { [weak self] in
            for _ in 0..<90 {   // ~3 min
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.running, !self.suspended else { return }
                if audioCaptureAuthorized() {
                    elog("engine: System Audio Recording granted — rebuilding tap to capture audio")
                    _ = await self.session.restartStream()
                    return
                }
            }
        }
    }

    /// Rebuild the capture (tap + mic) if it stopped delivering — e.g. the default output device
    /// changed under the aggregate device. Retries every 2s. Called on wake/unlock.
    func recover() {
        guard running, !suspended, !recovering else { return }
        recovering = true
        Task { [weak self] in
            for attempt in 1...60 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.running else { break }
                if await self.session.restartStream() {
                    elog("engine: capture stream recovered (attempt \(attempt))")
                    break
                }
            }
            self?.recovering = false
        }
    }

    func start() async throws {
        let audioOK = audioCaptureAuthorized()   // preflight == granted
        let micOK = micAuthorized()
        // Fire the consent prompts if anything is missing. From the .app bundle (which carries the
        // NSAudioCaptureUsageDescription), TCCAccessRequest surfaces the "System Audio Recording
        // Only" dialog; AVCaptureDevice surfaces the Microphone one. We do NOT hard-block on an
        // undetermined system-audio grant — we start the tap anyway (silent until granted) and
        // rebuild it the moment the user allows, so capture just begins with no manual restart.
        if !audioOK || !micOK {
            elog("engine: requesting permissions (system-audio granted=\(audioOK), mic=\(micOK))")
            _ = requestPermissions()
        }
        try await session.start()
        running = true
        elog("engine: recording (segment=\(Int(cfg.segmentSeconds))s, voiceMin=\(Int(cfg.voiceMinSeconds))s, exclude=\(cfg.excludeBundleIds.joined(separator: ",")))")
        if !audioOK { waitForAudioGrantThenRestart() }   // rebuild the muted tap once the user allows
        processQueue.async { [weak self] in self?.cleanupRetention() }   // tidy old files on start
        // Sleep/wake: stop capture cleanly on sleep and resume on wake.
        let wc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.suspendForSleep() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.wake() }
        }
        // An excluded app launching (or relaunching with a new pid) after the tap was built is NOT
        // excluded by it — the tap froze a set of process object IDs. Re-scan on launch/quit and rebuild
        // only when the set actually drifted. Debounced: an app's helper processes appear in a burst.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleExclusionRefresh()
            }
        }
        // Screen lock/unlock (distributed notifications) — pause while locked, too.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.suspendForSleep() }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.wake() }
        // Clock alignment: snap the first rotation to a clock boundary (top of the hour, or a multiple of the segment size).
        // E.g. segment=3600 → next :00; 900 → next :00/:15/:30/:45.
        let cal = Calendar.current; let nowD = Date()
        let intoHour = Double(cal.component(.minute, from: nowD) * 60 + cal.component(.second, from: nowD))
        let firstDelay = cfg.segmentSeconds - intoHour.truncatingRemainder(dividingBy: cfg.segmentSeconds)
        elog("engine: first rotation in \(Int(firstDelay))s (clock-aligned), then every \(Int(cfg.segmentSeconds))s")
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + firstDelay, repeating: cfg.segmentSeconds)
        t.setEventHandler { [weak self] in
            guard let self = self, let seg = self.session.rotate() else { return }
            self.processQueue.async { self.process(seg); self.cleanupRetention() }
        }
        t.resume()
        timer = t
    }

    /// Finalize the current segment and stop the stream (called on shutdown). The trailing partial
    /// segment is discarded (not transcribed) to keep shutdown fast.
    func stop() async {
        running = false   // set first so the stream-stopped event during shutdown doesn't trigger recover()
        timer?.cancel(); timer = nil
        let seg = await session.stop()
        if let seg = seg {
            try? FileManager.default.removeItem(at: seg.sysURL)
            try? FileManager.default.removeItem(at: seg.micURL)
        }
        elog("engine: stopped (trailing partial segment discarded)")
    }

    /// CLI `sweep` entry — one retention/archive pass, synchronously.
    func runRetentionSweep() { cleanupRetention() }

    /// Age audio through the archive tiers (raw WAV → AAC → deleted) and drop expired transcripts.
    /// Recurses under each root so the monthly subfolders are covered too (transcripts/YYYY-MM/*.md,
    /// audioDir/YYYY-MM/*.{wav,m4a} plus any legacy layout). Runs on processQueue.
    private func cleanupRetention() {
        let fm = FileManager.default
        func ageDays(_ u: URL) -> Double? {
            guard let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return nil }
            return Date().timeIntervalSince(m) / 86400
        }
        if cfg.transcriptRetentionDays > 0,
           let en = fm.enumerator(at: cfg.transcriptsDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            var n = 0
            for case let u as URL in en where u.pathExtension.lowercased() == "md" {
                if let a = ageDays(u), a >= Double(cfg.transcriptRetentionDays) { try? fm.removeItem(at: u); n += 1 }
            }
            if n > 0 { elog("engine: retention — deleted \(n) md file(s) (>\(cfg.transcriptRetentionDays)d)") }
        }
        let policy = AudioArchivePolicy(rawDays: cfg.audioRawDays, totalDays: cfg.audioRetentionDays)
        guard let en = fm.enumerator(at: cfg.audioDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var deleted = 0, archived = 0
        var budget = 12   // bound conversions per sweep (~1 s each) — transcription shares this queue
        for case let u as URL in en {
            let ext = u.pathExtension.lowercased()
            if u.lastPathComponent.contains(".partial-"), let a = ageDays(u), a > 1 {
                try? fm.removeItem(at: u); continue   // temp left by a killed sweep
            }
            guard ext == "wav" || ext == "m4a", let a = ageDays(u) else { continue }
            switch policy.tier(ageDays: a) {
            case .deleted:
                try? fm.removeItem(at: u); deleted += 1
            case .compressed where ext == "wav" && budget > 0:
                budget -= 1   // count ATTEMPTS — a batch of corrupt WAVs must not afconvert forever
                let out = u.deletingPathExtension().appendingPathExtension("m4a")
                if AudioArchiver.compress(u, to: out) {
                    relinkTranscriptAudio(from: u)
                    try? fm.removeItem(at: u)
                    archived += 1
                }
            default: break
            }
        }
        if deleted > 0 || archived > 0 {
            elog("engine: retention — deleted \(deleted) audio file(s), AAC-compressed \(archived) (raw>\(cfg.audioRawDays)d)")
        }
    }

    /// After archiving audio/YYYY-MM/<slug>.wav → .m4a, point the matching transcript's audio link
    /// at the new file. The transcript shares the slug: transcripts/YYYY-MM/<slug>.md.
    private func relinkTranscriptAudio(from wav: URL) {
        let slug = wav.deletingPathExtension().lastPathComponent
        let month = wav.deletingLastPathComponent().lastPathComponent
        let md = cfg.transcriptsDir.appendingPathComponent(month).appendingPathComponent("\(slug).md")
        guard let text = try? String(contentsOf: md, encoding: .utf8), text.contains("\(slug).wav") else { return }
        let mdate = (try? md.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        try? text.replacingOccurrences(of: "\(slug).wav", with: "\(slug).m4a")
            .write(to: md, atomically: true, encoding: .utf8)
        // The rewrite must not reset the transcript's own retention clock.
        if let mdate { try? FileManager.default.setAttributes([.modificationDate: mdate], ofItemAtPath: md.path) }
    }

    private func process(_ seg: CompletedSegment) {
        elog("engine: segment \(segFormatter().string(from: seg.start)) — voiced mic=\(String(format: "%.1f", seg.micVoicedSeconds))s sys=\(String(format: "%.1f", seg.sysVoicedSeconds))s (micPeak=\(String(format: "%.3f", seg.micPeak)) sysPeak=\(String(format: "%.3f", seg.sysPeak))) dur=\(Int(seg.durationSeconds))s")
        // Dead/misrouted input detector: the ENERGY gate says the mic was active, but nothing held
        // above the threshold for speech-length runs — clicks/hum, not a voice. Surface it instead
        // of silently discarding "no speech" segments for hours (the jack-input incident).
        if micLooksDead(voiced: seg.micVoicedSeconds, speech: seg.micSpeechSeconds) {
            elog("engine: MIC WARNING — energy without speech-length runs; input device may be dead/misrouted")
            onSegmentResult?("Mic looks dead — check the input device (Sound → Input)")
            if !warnedDeadMic {
                warnedDeadMic = true
                Notifier.push(title: "macrec can't hear a voice",
                              body: "The mic records energy but nothing speech-like. Check System Settings → Sound → Input.")
            }
        }
        // debugKeepTrackAudio: keep the PER-TRACK mic/sys wavs (normally deleted after the mix) in
        // workDir — transcription-quality A/B work (echo-dedup validation against real meetings)
        // needs the separated tracks, and the mixed wav can't be un-mixed. Off by default; workDir
        // lives under /tmp, so leftovers vanish on reboot regardless.
        let keepTracks = Pref.bool("debugKeepTrackAudio", "MR_DEBUG_KEEP_TRACKS", false)
        defer {
            if !keepTracks {
                try? FileManager.default.removeItem(at: seg.sysURL)
                try? FileManager.default.removeItem(at: seg.micURL)
            }
        }

        // Transcribe if anyone spoke — my mic or the other side (system) — including listen-only meetings.
        guard seg.voicedSeconds >= cfg.voiceMinSeconds else {
            elog("engine:   → no speech (\(String(format: "%.1f", seg.voicedSeconds))s < \(Int(cfg.voiceMinSeconds))s), discarding")
            onSegmentResult?("No speech — skipped")
            return
        }
        // Short-blip filter (user rule): when calendar titling is on, a segment with NO overlapping
        // meeting and under 3 min of speech isn't worth a file — meetings are always kept. Gate BEFORE
        // transcription so throwaway blips never reach whisper. (Only when titling is on: without a
        // calendar we can't tell "no meeting" from "a meeting we couldn't see", so we don't discard.)
        // ONE calendar query per segment: whisper runs for minutes between the gate and the write, and
        // two queries can return different answers.
        let meeting = cfg.useCalendarTitles
            ? CalendarLookup.match(start: seg.start, end: seg.start.addingTimeInterval(seg.durationSeconds))
            : nil
        if cfg.useCalendarTitles {
            guard shouldKeepTranscript(hasMeeting: meeting != nil, speechSeconds: seg.speechSeconds) else {
                elog("engine:   → no meeting & speech \(String(format: "%.0f", seg.speechSeconds))s < 180s — discarding")
                onSegmentResult?("No meeting · short — skipped")
                return
            }
        }
        // Model not downloaded yet (first run) — defer rather than write a "transcription failed" file.
        guard FileManager.default.fileExists(atPath: cfg.whisperModel) else {
            elog("engine:   → model not ready (\(cfg.whisperModel)) — deferring transcription")
            onSegmentResult?("Downloading model — transcription deferred")
            return
        }
        onSegmentResult?("Transcribing…")
        guard let (mixed, text) = Transcriber.transcribe(seg, cfg: cfg) else {
            onSegmentResult?("Transcription failed")   // a waiting "Transcribe now" push must not dangle
            return
        }
        // A segment can pass the energy gate (keyboard noise, a cough) yet transcribe to NOTHING —
        // those "auto transcript" shells with an empty body were piling up hourly (user report).
        // No transcript lines → no file, and the mixed WAV goes too (nothing to reference it).
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let mixed { try? FileManager.default.removeItem(at: mixed) }
            elog("engine: segment transcribed to nothing — discarded (mic \(String(format: "%.1f", seg.micVoicedSeconds))s, sys \(String(format: "%.1f", seg.sysVoicedSeconds))s)")
            onSegmentResult?("No speech — discarded")
            return
        }
        do {
            let url = try writeTranscript(seg: seg, text: text, mixed: mixed, event: meeting)
            onTranscriptURL?(url)
            onTranscriptSaved?("Saved: \(url.lastPathComponent)")
            if let cmd = postProcessInvocationFromPrefs(transcriptPath: url.path) {
                let file = url.lastPathComponent
                SummaryStatus.shared.started(file)
                let mode = effectivePostProcessMode(rawMode: Pref.explicit(Pref.postProcessMode, "MR_POST_PROCESS_MODE"),
                                                    shellCmd: Pref.postProcessCommand)
                // A shell hook writes nowhere we know, so there is no file to reveal and no partial to reap.
                let out = postProcessWritesSummaryFile(mode)
                    ? summaryOutputPath(transcriptPath: url.path, outDir: Pref.explicit(Pref.summaryOut, "MR_SUMMARY_OUT"))
                    : nil
                runPostProcessCommand(cmd) { status in
                    guard status != 0 else { SummaryStatus.shared.finished(file, at: Date(), output: out); return }
                    let why = out.flatMap { reapFailedPostProcess(outPath: $0) }
                    SummaryStatus.shared.failed(file, at: Date(), reason: why)
                    elog("engine: post-process exited \(status) for \(file)" + (why.map { " — \($0)" } ?? ""))
                    Notifier.push(title: "Summary failed",
                                  body: why ?? "The summary command exited with code \(status) — check Settings › Summaries.")
                }
            }
        } catch { elog("engine: writeTranscript: \(error)") }
    }

    @discardableResult
    private func writeTranscript(seg: CompletedSegment, text: String, mixed: URL?,
                                 event: CalendarLookup.Match?) throws -> URL {
        let fm = FileManager.default
        let dayF = DateFormatter(); dayF.locale = Locale(identifier: "en_US_POSIX"); dayF.dateFormat = "yyyy-MM-dd"
        let hmF = DateFormatter(); hmF.locale = Locale(identifier: "en_US_POSIX"); hmF.dateFormat = "HH:mm"
        let monthF = DateFormatter(); monthF.locale = Locale(identifier: "en_US_POSIX"); monthF.dateFormat = "yyyy-MM"

        let end = seg.start.addingTimeInterval(seg.durationSeconds)

        // The overlapping calendar event, resolved ONCE by the caller (see `process`).
        let l10n = TranscriptL10n.current
        let title = event?.title ?? l10n.autoTitle
        // Stamp the file with the MEETING's start when one maps, else the segment's. Name, month
        // folder and the header's range all derive from this one value so they can never disagree.
        let stamp = transcriptStart(segStart: seg.start, segEnd: end, eventStart: event?.start)
        let mins = max(1, Int((end.timeIntervalSince(stamp) + 30) / 60))
        let base = transcriptBaseName(start: stamp)
        let slug = event.map { "\(base)-\(slugify($0.title))" } ?? base

        // Organize transcripts into monthly subfolders: transcripts/YYYY-MM/…  (audio under YYYY-MM/audio/).
        let monthDir = cfg.transcriptsDir.appendingPathComponent(monthF.string(from: stamp), isDirectory: true)
        try fm.createDirectory(at: monthDir, withIntermediateDirectories: true)

        // keep the mixed WAV per the keepAudio setting (mixed is nil when keepAudio is off)
        var audioLine = "- \(l10n.audio): \(l10n.audioNotKept)"
        if cfg.keepAudio, let mixed = mixed {
            let audioMonthDir = cfg.audioDir.appendingPathComponent(monthF.string(from: stamp), isDirectory: true)
            try fm.createDirectory(at: audioMonthDir, withIntermediateDirectories: true)
            let keptAudio = audioMonthDir.appendingPathComponent("\(slug).wav")
            try? fm.removeItem(at: keptAudio)
            try fm.moveItem(at: mixed, to: keptAudio)
            audioLine = "- \(l10n.audio): [\(slug).wav](\(relativePath(fromDir: monthDir, toFile: keptAudio)))"
        }

        var meta = ""
        if let link = event?.link { meta += "\n- \(l10n.meetingLink): \(link)" }
        if let names = event?.attendees, !names.isEmpty { meta += "\n- \(l10n.attendees): \(names.prefix(12).joined(separator: ", "))" }

        // The body's speaker labels follow the TRANSCRIPTION language (same derivation as Transcriber).
        let bodyLang = cfg.whisperLang == "auto" ? Locale.current.language.languageCode?.identifier : cfg.whisperLang
        let (bodyMine, bodyTheirs) = speakerLabels(forLanguage: bodyLang)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? l10n.failureNote(model: cfg.whisperModel) : text
        let doc = TranscriptDoc(
            title: title,
            day: dayF.string(from: stamp), hmStart: hmF.string(from: stamp), hmEnd: hmF.string(from: end),
            mins: mins,
            micVoiced: seg.micVoicedSeconds, sysVoiced: seg.sysVoicedSeconds,
            modelName: URL(fileURLWithPath: cfg.whisperModel).lastPathComponent,
            audioLine: audioLine, meta: meta, excludes: cfg.excludeBundleIds.joined(separator: ", "),
            bodyMine: bodyMine, bodyTheirs: bodyTheirs,
            body: body)
        let mdURL = monthDir.appendingPathComponent("\(slug).md")
        try doc.markdown(l10n).write(to: mdURL, atomically: true, encoding: .utf8)
        elog("engine:   → transcript saved: \(mdURL.path)")
        return mdURL
    }
}

// MARK: - audio archive tiers (raw WAV → AAC after N days → deleted after M days)
//
// An hour of voiced 16 kHz mono PCM is ~115 MB; the same hour as 32 kbps AAC is ~14 MB (⅛).
// Recent segments stay WAV (instant scrubbing / re-transcription); older ones are archived to
// .m4a and the transcript's audio link is rewritten to match. Deletion applies to both forms.

enum AudioTier: Equatable { case raw, compressed, deleted }

struct AudioArchivePolicy: Equatable {
    var rawDays: Int      // days a file stays raw WAV; 0 = never compress
    var totalDays: Int    // age at which audio (raw or compressed) is deleted; 0 = keep forever

    func tier(ageDays: Double) -> AudioTier {
        if totalDays > 0, ageDays >= Double(totalDays) { return .deleted }   // delete beats compress
        if rawDays > 0, ageDays >= Double(rawDays) { return .compressed }
        return .raw
    }

    /// Combo-box text → days. "90 days" / "6 months" / "2 weeks" / "1 year" / bare "45";
    /// "Unlimited" / "Don't compress" / "0" → 0 (forever / never). nil = unparseable.
    static func parseRetentionDays(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return nil }
        if t == "0" || t.hasPrefix("unlimited") || t.hasPrefix("forever")
            || t.hasPrefix("never") || t.hasPrefix("don") { return 0 }
        let digits = t.prefix { $0.isNumber }
        guard !digits.isEmpty, let n = Int(digits), n >= 0 else { return nil }
        let unit = t.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        // checked multiply: this runs on every Settings keystroke — pasting "…775807 years" must
        // turn the field red, not trap and kill the recorder mid-meeting.
        func mul(_ b: Int) -> Int? {
            let r = n.multipliedReportingOverflow(by: b); return r.overflow ? nil : r.partialValue
        }
        if unit.isEmpty || unit.hasPrefix("d") { return n }
        if unit.hasPrefix("w") { return mul(7) }
        if unit.hasPrefix("mo") { return mul(30) }
        if unit.hasPrefix("y") { return mul(365) }
        return nil
    }

    static func retentionTitle(_ days: Int) -> String {
        if days == 0 { return "Unlimited" }
        if days % 365 == 0 { return days == 365 ? "1 year" : "\(days / 365) years" }
        return "\(days) days"
    }
}

enum AudioArchiver {
    /// WAV → AAC 32 kbps .m4a (afconvert). Writes to a .partial temp, then promotes — a killed
    /// sweep never leaves a half-written archive behind. The original's modification date is
    /// carried over so the retention clock keeps counting from RECORDING time, not archive time.
    /// 16 kHz mono rejects higher AAC bitrates (64k fails with '!dat'), so 32k is also the ceiling.
    static func compress(_ wav: URL, to out: URL) -> Bool {
        let fm = FileManager.default
        // pid-unique temp: the tray app's sweep and a manual `macrec sweep` can overlap — a shared
        // temp name would let one process promote the other's still-being-written file.
        let tmp = out.appendingPathExtension("partial-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: tmp)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "m4af", "-d", "aac", "-b", "32000", wav.path, tmp.path]
        do { try p.run() } catch { elog("archive: afconvert launch failed: \(error)"); return false }
        p.waitUntilExit()
        let size = (try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? Int ?? 0
        guard p.terminationStatus == 0, size > 0 else {
            elog("archive: afconvert failed (status \(p.terminationStatus)) — keeping \(wav.lastPathComponent)")
            try? fm.removeItem(at: tmp)
            return false
        }
        let mdate = (try? wav.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        try? fm.removeItem(at: out)
        do { try fm.moveItem(at: tmp, to: out) } catch { try? fm.removeItem(at: tmp); return false }
        if let mdate { try? fm.setAttributes([.modificationDate: mdate], ofItemAtPath: out.path) }
        return true
    }
}

// MARK: - recording schedule (record only Mon–Fri 10:00–19:00, minus lunch — instead of 24/7)
//
// Days ("mon-fri", "mon,wed,fri") and hour ranges ("10:00-12:00, 13:00-19:00" — the gap between
// ranges IS the lunch exclusion). Outside the window the engine is suspended; a manual Pause/Resume
// overrides the schedule until the next boundary.

struct RecordSchedule: Equatable {
    var enabled: Bool
    var weekdays: Set<Int>            // 1=Sun … 7=Sat (Calendar.component(.weekday))
    var ranges: [(start: Int, end: Int)]   // minutes since midnight, half-open [start, end)

    static func == (a: RecordSchedule, b: RecordSchedule) -> Bool {
        a.enabled == b.enabled && a.weekdays == b.weekdays
            && a.ranges.map { $0.start } == b.ranges.map { $0.start }
            && a.ranges.map { $0.end } == b.ranges.map { $0.end }
    }

    /// Users paste schedules from Notes/Slack where autocorrect swaps "-" for – / —, and Korean/Japanese
    /// input naturally writes ranges as 10:00~19:00 with full-width punctuation — accept all of it.
    static func normalized(_ s: String) -> String {
        var t = s
        for dash in ["–", "—", "−", "~", "〜", "～"] { t = t.replacingOccurrences(of: dash, with: "-") }
        for (from, to) in [("：", ":"), ("、", ","), ("，", ",")] { t = t.replacingOccurrences(of: from, with: to) }
        return t
    }

    /// "mon-fri" / "sat-mon" (wraps) / "mon,wed,fri" / "" → empty set. Case-insensitive. Pure + testable.
    static func parseDays(_ s: String) -> Set<Int> {
        let names = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
        var out = Set<Int>()
        for part in normalized(s).lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let dash = part.firstIndex(of: "-") {
                guard let a = names[String(part[..<dash]).trimmingCharacters(in: .whitespaces)],
                      let b = names[String(part[part.index(after: dash)...]).trimmingCharacters(in: .whitespaces)] else { continue }
                var d = a
                while true { out.insert(d); if d == b { break }; d = d % 7 + 1 }   // wraps sat-mon
            } else if let d = names[part] {
                out.insert(d)
            }
        }
        return out
    }

    /// "10:00-12:00, 13:00-19:00" → minute ranges; "24:00" allowed as end-of-day. A start AFTER its
    /// end ("22:00-06:00") wraps past midnight into two ranges. Bad chunks skipped.
    static func parseRanges(_ s: String) -> [(start: Int, end: Int)] {
        func minutes(_ t: String) -> Int? {
            let p = t.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard p.count == 2, let h = p[0], let m = p[1], (0...24).contains(h), (0..<60).contains(m),
                  h < 24 || m == 0 else { return nil }
            return h * 60 + m
        }
        return normalized(s).split(separator: ",").flatMap { chunk -> [(start: Int, end: Int)] in
            let sides = chunk.split(separator: "-", maxSplits: 1).map(String.init)
            guard sides.count == 2, let a = minutes(sides[0]), let b = minutes(sides[1]), a != b else { return [] }
            if a < b { return [(a, b)] }
            return [(a, 1440), (0, b)].filter { $0.0 < $0.1 }   // overnight, e.g. 22:00-06:00
        }
    }

    /// A non-empty field where SOME chunk didn't parse is a typo, not intent — the Settings pane
    /// paints the field red so "10am-7pm" can't silently fall back to record-everything.
    static func daysValid(_ s: String) -> Bool { chunksOK(s) { !parseDays($0).isEmpty } }
    static func hoursValid(_ s: String) -> Bool { chunksOK(s) { !parseRanges($0).isEmpty } }
    private static func chunksOK(_ s: String, _ ok: (String) -> Bool) -> Bool {
        normalized(s).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.allSatisfy(ok)
    }

    static func from(enabled: Bool, days: String, hours: String) -> RecordSchedule {
        RecordSchedule(enabled: enabled, weekdays: parseDays(days), ranges: parseRanges(hours))
    }

    /// Should recording run at `date`? Disabled schedule = always. An enabled schedule with an EMPTY
    /// days/ranges field treats that dimension as "every day" / "all hours" (a half-filled form must
    /// never silently stop all recording).
    func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return true }
        if !weekdays.isEmpty, !weekdays.contains(calendar.component(.weekday, from: date)) { return false }
        guard !ranges.isEmpty else { return true }
        let mins = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return ranges.contains { mins >= $0.start && mins < $0.end }
    }

    /// First active↔inactive flip after `date` (minute granularity), or nil when the schedule never
    /// changes state (disabled, or empty fields = always on). A manual override stores this as its
    /// EXPIRY TIMESTAMP — comparing against wall-clock time survives sleeping across any number of
    /// boundaries, where edge-detection on sampled state misses even flip counts.
    func nextBoundary(after date: Date, calendar: Calendar = .current) -> Date? {
        guard enabled, !(weekdays.isEmpty && ranges.isEmpty) else { return nil }
        let startActive = isActive(at: date, calendar: calendar)
        var t = date.addingTimeInterval(60 - date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60))
        let limit = date.addingTimeInterval(8 * 86400)   // 11,520 one-minute probes worst case — trivial
        while t <= limit {
            if isActive(at: t, calendar: calendar) != startActive { return t }
            t = t.addingTimeInterval(60)
        }
        return nil
    }

    static var fromPrefs: RecordSchedule {
        from(enabled: Pref.bool(Pref.schedEnabled, "MR_SCHEDULE", false),
             days: Pref.explicit(Pref.schedDays, "MR_SCHEDULE_DAYS"),
             hours: Pref.explicit(Pref.schedHours, "MR_SCHEDULE_HOURS"))
    }
}

/// Dead/misrouted-input verdict: plenty of ENERGY-gate "voiced" time but almost none of it in
/// sustained speech-length runs. Real speech always forms >=50 ms runs; electrical clicks and hum
/// from a mic-less input never do. Pure + testable.
func micLooksDead(voiced: Double, speech: Double) -> Bool {
    voiced >= 5 && speech < 0.5
}

/// Reference implementation of the writer's speech-run accounting (samples inside >=minRun
/// contiguous above-threshold runs) — selftests pin the semantics here.
func speechlikeFrames(_ samples: [Float], threshold: Float = 0.02, minRun: Int = 800) -> Int {
    var total = 0, run = 0
    for a in samples.map({ abs($0) }) {
        if a > threshold {
            run += 1
            if run == minRun { total += run } else if run > minRun { total += 1 }
        } else { run = 0 }
    }
    return total
}

/// Self-clocking tail scheduler's fire decision — exactly one request in flight, refire only when
/// the tail actually moved, never after finalization. Pure + testable (the timing regressions
/// "not real-time" and "second line slow" both lived in this decision).
func shouldFireTailTranslation(tail: String, lastSent: String, inFlight: Bool, final: Bool) -> Bool {
    !final && !inFlight && !tail.isEmpty && tail != lastSent
}

/// Sentences that have COMPLETED inside a growing partial (terminator seen) — the unfinished tail
/// is excluded. A '.' only terminates when followed by whitespace, so "3.5" never splits and the
/// final period of a still-streaming line waits for its confirming space. Drives sentence-streamed
/// live translation. Pure + testable.
func completeSentences(_ text: String) -> [String] {
    var out: [String] = []
    var cur = ""
    let hard: Set<Character> = ["!", "?", "。", "！", "？", "…"]
    let chars = Array(text)
    for (i, ch) in chars.enumerated() {
        cur.append(ch)
        let ends = hard.contains(ch) || (ch == "." && i + 1 < chars.count && chars[i + 1].isWhitespace)
        if ends {
            let t = cur.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(t) }
            cur = ""
        }
    }
    return out
}

// MARK: - transcript-level echo suppression (belt to the AEC's braces)
//
// The acoustic canceller attenuates the speaker→mic echo ~15-26 dB, but live engines still transcribe
// the residual: the far-end shows up again under the MIC speaker as an (often garbled) copy a moment
// later. Acoustic cancellation can't fully win that fight, so we also suppress at the TRANSCRIPT
// level: a mic line whose tokens are largely contained in a recent far-end line is an echo, not the
// user. One-directional (system audio can't contain the user's voice) and length-guarded so genuine
// short replies ("yes", "right") are never eaten.

/// Containment similarity of `a` in `b`: fraction of `a`'s unique tokens present in `b` (echo copies
/// are garbled SUBSETS of the far-end line, so containment beats symmetric Jaccard). Pure + testable.
func echoSimilarity(_ a: String, _ b: String) -> Double {
    func toks(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }
    let ta = toks(a), tb = toks(b)
    guard !ta.isEmpty, !tb.isEmpty else { return 0 }
    return Double(ta.intersection(tb).count) / Double(ta.count)
}

/// Is the MIC text most likely the far-end's echo? ≥ 4 tokens (protects genuine short replies) and
/// ≥ 80% of its tokens contained in the far-end line.
func isLikelyEcho(mine: String, theirs: String) -> Bool {
    let tokens = mine.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    return tokens.count >= 4 && echoSimilarity(mine, theirs) >= 0.8
}

/// Drop mic-speaker lines that are echoes of a nearby (±windowSec) far-end line in a merged,
/// time-sorted transcript. Pure + testable — used by the saved-transcript merge.
func suppressEchoLines(_ merged: [(start: Double, who: String, text: String)], mine: String,
                       windowSec: Double = 8) -> [(start: Double, who: String, text: String)] {
    merged.filter { line in
        guard line.who == mine else { return true }
        return !merged.contains { other in
            other.who != mine && abs(other.start - line.start) <= windowSec
                && isLikelyEcho(mine: line.text, theirs: other.text)
        }
    }
}

// MARK: - transcription hints (a proper-noun dictionary biases recognition toward YOUR vocabulary)
//
// whisper's initial prompt (--prompt) steers decoding toward the given tokens — team/product names,
// domain jargon, attendee names stop coming out mangled. Merged from three sources: the Settings terms,
// an external file (git-manageable), and optionally the overlapping calendar event.

/// Split a hints blob into terms: comma- or newline-separated, trimmed. A `#` starts a comment that
/// runs to the END OF THE LINE — commas inside a comment must not resurrect its tail as terms
/// (review finding: "# old, stuff" leaked "stuff" into prompts).
func parseHintTerms(_ text: String) -> [String] {
    text.split(separator: "\n")
        .map { line in line.firstIndex(of: "#").map { String(line[..<$0]) } ?? String(line) }
        .flatMap { $0.split(separator: ",") }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

/// Merge hint sources in priority order, dedupe case-insensitively, cap the count (whisper's prompt
/// window is small — past ~60 terms the tail is ignored anyway). Pure + testable.
func mergeHintTerms(direct: [String], file: [String], event: [String], cap: Int = 60) -> [String] {
    var seen = Set<String>(), out: [String] = []
    for t in direct + file + event where out.count < cap {
        let k = t.lowercased()
        if !seen.contains(k) { seen.insert(k); out.append(t) }
    }
    return out
}

/// Assemble the effective hints prompt for a recording window from prefs (+ calendar when enabled).
func transcriptionHints(start: Date, end: Date) -> String {
    let direct = parseHintTerms(Pref.explicit(Pref.hintsTerms, "MR_HINTS"))
    var file: [String] = []
    let fp = Pref.explicit(Pref.hintsFile, "MR_HINTS_FILE").trimmingCharacters(in: .whitespacesAndNewlines)
    if !fp.isEmpty {
        let path = (fp as NSString).expandingTildeInPath
        if let txt = try? String(contentsOfFile: path, encoding: .utf8) { file = parseHintTerms(txt) }
        else { elog("hints: couldn't read \(path) — skipping the file terms") }
    }
    var event: [String] = []
    if Pref.bool(Pref.hintsCalendar, "MR_HINTS_CALENDAR", false), let e = CalendarLookup.match(start: start, end: end) {
        event = [e.title] + e.attendees
    }
    return mergeHintTerms(direct: direct, file: file, event: event).joined(separator: ", ")
}

// MARK: - post-process hook (ETL stage 1: the app triggers, the user's script pipelines)
//
// After each transcript is saved, run the user's command with the file path appended — summarize with
// an LLM, translate, load into a notes DB, whatever; the pipeline lives in the user's script, so it
// changes without an app release. Runs in a LOGIN shell (`zsh -lc`) so PATH/brew/rc setup apply.
/// Fire-and-forget: a slow or hung hook can never block the engine. Output (both streams) is read to
/// EOF BEFORE waiting on exit — reading after would deadlock once the pipe buffer fills. `completion`
/// receives the exit status (or -1 when the launch itself failed); used by the selftest.
/// Shell-quote a single argument for the zsh command line.
func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

enum PostProcessMode: String { case off, summary, shell }
enum SummaryRunner: String, CaseIterable { case claude, codex, gemini }

/// The built-in summary prompt — the turn-key default (editable in Settings). Answering in the
/// transcript's own language keeps it correct for mixed ko/en/ja meetings.
let defaultSummaryPrompt = "Summarize this meeting transcript: key points, decisions made, and action items with owners. Answer in the same language as the transcript."

/// Where the automatic summary lands. A dedicated output dir mirrors the transcripts' monthly
/// layout with the PLAIN transcript name (`<dir>/YYYY-MM/<name>.md` — the folder already says
/// "summary", and `.summary.md` read as clutter); only the next-to-the-transcript fallback ("")
/// keeps a short `-sum` marker to avoid colliding with the transcript itself. Pure + testable.
/// (The invocation mkdir -p's the parent, so the month folder appears on first use.)
func summaryOutputPath(transcriptPath: String, outDir: String) -> String {
    let t = URL(fileURLWithPath: transcriptPath)
    let base = t.deletingPathExtension().lastPathComponent
    let dir = outDir.trimmingCharacters(in: .whitespacesAndNewlines)
    if dir.isEmpty { return t.deletingLastPathComponent().appendingPathComponent("\(base)-sum.md").path }
    var root = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
    let month = String(base.prefix(7))                                     // "2026-07" from the file name
    if month.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil {
        root.appendPathComponent(month, isDirectory: true)
    }
    return root.appendingPathComponent("\(base).md").path
}

/// Build the shell invocation for a post-process run — nil when there's nothing to do. Pure + testable.
/// BUILT-IN (summary): the agent CLI gets the prompt and the transcript on stdin, output redirected to
/// the summary path. FREEFORM (shell): the user's command with the transcript path appended.
func postProcessInvocation(mode: PostProcessMode, runner: SummaryRunner, prompt: String, shellCmd: String,
                           transcriptPath: String, outDir: String) -> String? {
    switch mode {
    case .off:
        return nil
    case .shell:
        let c = shellCmd.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? nil : c + " " + shq(transcriptPath)
    case .summary:
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = p.isEmpty ? defaultSummaryPrompt : p
        let out = summaryOutputPath(transcriptPath: transcriptPath, outDir: outDir)
        let dir = URL(fileURLWithPath: out).deletingLastPathComponent().path
        let runnerCmd: String
        switch runner {
        case .claude: runnerCmd = "claude -p \(shq(effective)) < \(shq(transcriptPath))"
        case .gemini: runnerCmd = "gemini -p \(shq(effective)) < \(shq(transcriptPath))"
        // codex exec takes the prompt from stdin with `-`; prepend it to the transcript.
        case .codex:  runnerCmd = "{ printf '%s\\n\\n' \(shq(effective)); cat \(shq(transcriptPath)); } | codex exec -"
        }
        // The output dir may not exist (review finding: the redirect just failed); and a failed run
        // must not leave a misleading empty .summary.md — write .partial, promote only on success.
        return "mkdir -p \(shq(dir)) && \(runnerCmd) > \(shq(out + ".partial")) && mv \(shq(out + ".partial")) \(shq(out))"
    }
}

/// The effective mode. Migration (review finding): v1 had no mode key — the hook fired whenever the
/// command was set. An UNSET mode with a non-empty v1 command (pref or MR_POST_PROCESS) therefore
/// means `.shell`, or upgrading would silently kill an existing pipeline. Pure + testable.
func effectivePostProcessMode(rawMode: String, shellCmd: String) -> PostProcessMode {
    if let m = PostProcessMode(rawValue: rawMode) { return m }
    return shellCmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .off : .shell
}

/// Whether a completed segment is worth a transcript file. A segment that overlapped a calendar MEETING
/// is always kept; an ad-hoc recording with no meeting is kept only when there was real speech — at least
/// `minNonMeetingSeconds` (default 3 min) — so short non-meeting blips (a hallway chat, a passing video)
/// don't litter the notes (user rule). Pure + selftested.
func shouldKeepTranscript(hasMeeting: Bool, speechSeconds: Double, minNonMeetingSeconds: Double = 180) -> Bool {
    hasMeeting || speechSeconds >= minNonMeetingSeconds
}

/// Read the post-process prefs and build the invocation for a just-saved transcript.
/// The effective summary prompt: a readable prompt FILE overrides the inline text (same "…or file"
/// pattern as the hints; keep the prompt in your notes repo and iterate without touching Settings).
/// An unreadable configured file falls back to the inline text — and logs, never fails silently.
func effectiveSummaryPrompt(inline: String, filePath: String) -> String {
    let fp = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
    if !fp.isEmpty {
        let path = (fp as NSString).expandingTildeInPath
        if let txt = try? String(contentsOfFile: path, encoding: .utf8),
           !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return txt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        elog("summary: couldn't read prompt file \(path) — using the inline prompt")
    }
    return inline
}

// MARK: L3 — daily digest (see PIPELINE.md; aggregates the day's summaries at a set time)

let defaultDailyDigestPrompt = "These are summaries (or transcripts) of one day's meetings, in "
    + "chronological order. Write a daily digest: an overview of the day, highlights per meeting, "
    + "and a combined list of decisions and action items with owners. Answer in the same language "
    + "as the input."

/// Is the daily digest due? True once `now` passes today's HH:mm deadline and today's digest
/// hasn't run yet. The last-run marker (not a fired timer) is what makes a slept-through deadline
/// CATCH UP on wake instead of skipping the day. Pure + testable.
func dailyDigestDue(now: Date, time: String, lastRun: String, calendar: Calendar = .current) -> Bool {
    let hm = time.split(separator: ":").compactMap { Int($0) }
    guard hm.count == 2, (0..<24).contains(hm[0]), (0..<60).contains(hm[1]) else { return false }
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"
    let today = f.string(from: now)
    guard lastRun != today else { return false }
    let mins = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
    return mins >= hm[0] * 60 + hm[1]
}

/// Should the day be marked done, given how the digest ended? Only a run that produced a file, or one
/// that can never succeed today (nothing to summarize, a name that would clobber a note), retires the
/// day. A runner that failed — no login, no network — must be retried on the next tick, or a transient
/// error at 20:00 silently costs the whole day. Pure + selftested.
enum DigestOutcome: Equatable { case wrote, nothingToDo, wouldOverwrite, runnerFailed }
func digestMarksDayDone(_ outcome: DigestOutcome) -> Bool {
    switch outcome {
    case .wrote, .nothingToDo, .wouldOverwrite: return true
    case .runnerFailed:                         return false
    }
}

/// The digest's file name from a user template: `{date}` / `{month}`, default `{date}.md`. Separators
/// are stripped (a `/` would escape the month folder) and the day is forced in — a template without it
/// resolves to one path for the whole month and the atomic `mv` would eat yesterday. Pure + selftested.
let dailyDigestNameDefault = "{date}.md"
func dailyDigestFileName(day: String, template: String = dailyDigestNameDefault) -> String {
    let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
    var name = (t.isEmpty ? dailyDigestNameDefault : t)
        .replacingOccurrences(of: "{date}", with: day)
        .replacingOccurrences(of: "{month}", with: String(day.prefix(7)))
        .replacingOccurrences(of: "/", with: "-")
    if !name.lowercased().hasSuffix(".md") { name += ".md" }
    if name == ".md" { name = "\(day).md" }
    // A template with no {date} ("notes.md", or only {month}) resolves to the SAME path every day of
    // the month, and the digest's atomic promote is an `mv` — yesterday's digest would be overwritten
    // without a word. The day is not negotiable; the rest of the name is the user's.
    return name.contains(day) ? name : "\(day)-\(name)"
}

/// The day's digest inputs: the meeting SUMMARY where one exists, else the transcript, joined on the
/// shared `yyyy-MM-dd-HHmm` basename and sorted by name. `excluding` is the digest about to be written —
/// it shares the folder and the day prefix, so without this it feeds on its own output.
func dailyDigestInputs(day: String, transcripts: [String], summaries: [String], excluding: String = "") -> [String] {
    let skip = excluding.isEmpty ? "" : URL(fileURLWithPath: excluding).standardizedFileURL.path
    func kept(_ p: String) -> Bool { skip.isEmpty || URL(fileURLWithPath: p).standardizedFileURL.path != skip }
    // A summary saved next to its transcript is named `<base>-sum.md` (summaryOutputPath). Keying the
    // map on the raw basename meant `<base>-sum` never matched `<base>`, so the digest silently fed on
    // raw transcripts instead of the compact summaries whenever "Save summary to" was left empty.
    let summaryByBase = Dictionary(summaries.filter(kept).map { p -> (String, String) in
        let b = URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent
        return (b.hasSuffix("-sum") ? String(b.dropLast(4)) : b, p)
    }, uniquingKeysWith: { a, _ in a })
    return transcripts
        .filter { kept($0) && URL(fileURLWithPath: $0).lastPathComponent.hasPrefix(day) }
        .sorted { URL(fileURLWithPath: $0).lastPathComponent < URL(fileURLWithPath: $1).lastPathComponent }
        .map { summaryByBase[URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent] ?? $0 }
}

/// Where the digest lands: `<dir>/YYYY-MM/<name>`. "" falls back to the summaries dir (or the
/// transcripts dir when summaries also default) — the same month folder as the day's notes. Pure.
func dailyDigestOutputPath(day: String, outDir: String, summaryOutDir: String, transcriptsDir: String,
                           nameTemplate: String = dailyDigestNameDefault) -> String {
    let dir = outDir.trimmingCharacters(in: .whitespacesAndNewlines)
    let sum = summaryOutDir.trimmingCharacters(in: .whitespacesAndNewlines)
    let root: URL
    if !dir.isEmpty {
        root = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
    } else if !sum.isEmpty {
        root = URL(fileURLWithPath: (sum as NSString).expandingTildeInPath)
    } else {
        root = URL(fileURLWithPath: transcriptsDir)
    }
    return root.appendingPathComponent(String(day.prefix(7)), isDirectory: true)
        .appendingPathComponent(dailyDigestFileName(day: day, template: nameTemplate)).path
}

/// Shell invocation for the digest: cat the day's inputs into the summary runner, atomic promote.
/// Same runner CLI templates and .partial contract as the per-meeting summary. Pure + testable.
func dailyDigestInvocation(runner: SummaryRunner, prompt: String, inputs: [String], outPath: String) -> String? {
    guard !inputs.isEmpty else { return nil }
    let dir = URL(fileURLWithPath: outPath).deletingLastPathComponent().path
    let cat = "cat " + inputs.map(shq).joined(separator: " ")
    let runnerCmd: String
    switch runner {
    case .claude: runnerCmd = "\(cat) | claude -p \(shq(prompt))"
    case .gemini: runnerCmd = "\(cat) | gemini -p \(shq(prompt))"
    case .codex:  runnerCmd = "{ printf '%s\\n\\n' \(shq(prompt)); \(cat); } | codex exec -"
    }
    return "mkdir -p \(shq(dir)) && \(runnerCmd) "
         + "> \(shq(outPath + ".partial")) && mv \(shq(outPath + ".partial")) \(shq(outPath))"
}

/// What post-processing is doing right now. Without this the pipeline is a black box: a summary runs
/// after a transcript is saved, leaves no trace, and the app looks broken.
enum SummaryActivity: Equatable {
    case off
    case idle
    case running(String)
    case done(String, Date)
    case failed(String, Date, reason: String?)
}

/// The tray row for post-processing. Pure + selftested.
func summaryMenuTitle(_ activity: SummaryActivity, hm: (Date) -> String) -> String {
    switch activity {
    case .off:                 return "Summaries: off"
    case .idle:                return "Summary: after the next transcript"
    case .running(let file):   return "Summary: running… \(file)"
    case .done(let file, let t):      return "Summary: \(file) · \(hm(t))"
    case .failed(let file, let t, _): return "Summary FAILED: \(file) · \(hm(t))"
    }
}

/// What clicking the summary row does. Enablement and the action come from ONE decision, so a row can
/// never be clickable and then do nothing — the defect this project keeps reproducing. Pure + selftested.
enum SummaryRowAction: Equatable {
    case none
    case reveal(String)              // the file it produced
    case explain(String, String?)    // (file, why it failed)
}
func summaryRowAction(_ activity: SummaryActivity, lastOutput: String?) -> SummaryRowAction {
    switch activity {
    case .failed(let file, _, let reason): return .explain(file, reason)
    case .done, .idle, .running:
        guard let out = lastOutput else { return .none }
        return .reveal(out)
    case .off: return .none
    }
}

/// The tray row for the daily digest. Pure + selftested.
func digestMenuTitle(enabled: Bool, dueTime: String, lastRun: String, today: String) -> String {
    guard enabled else { return "Daily digest: off" }
    if lastRun == today { return "Daily digest: written today" }
    return "Daily digest: due at \(dueTime)"
}

/// Last known post-processing activity. Written from the process queue, read on the main thread.
final class SummaryStatus {
    static let shared = SummaryStatus()
    private let lock = NSLock()
    private var activity: SummaryActivity = .idle
    private var lastPath: String?

    var current: SummaryActivity { lock.lock(); defer { lock.unlock() }; return activity }
    var lastOutput: String? { lock.lock(); defer { lock.unlock() }; return lastPath }
    /// Both halves under ONE lock: reading them separately lets a failure land between the two and the
    /// row then offers to reveal a file for a run that just failed.
    var snapshot: (SummaryActivity, String?) { lock.lock(); defer { lock.unlock() }; return (activity, lastPath) }

    func started(_ file: String) { lock.lock(); activity = .running(file); lock.unlock() }
    func finished(_ file: String, at date: Date, output: String?) {
        lock.lock(); activity = .done(file, date); lastPath = output; lock.unlock()
    }
    func failed(_ file: String, at date: Date, reason: String?) {
        lock.lock(); activity = .failed(file, date, reason: reason); lock.unlock()
    }
    func resetForTest() { lock.lock(); activity = .idle; lastPath = nil; lock.unlock() }
}

/// Does this mode write a summary file at the summary path? Only the built-in `.summary` mode redirects
/// into `<out>.partial` and promotes it. A freeform shell hook is handed the transcript and writes
/// wherever it likes — offering to reveal `<out>` after it runs would open a file that never existed,
/// and reading `<out>.partial` for a failure reason would find nothing. Pure + selftested.
func postProcessWritesSummaryFile(_ mode: PostProcessMode) -> Bool { mode == .summary }

/// A summary runner writes its STDOUT to `<out>.partial` and only then promotes it, so when it fails
/// the reason is inside that file, not on stderr — `claude` exiting 1 with "Not logged in · Please run
/// /login" left nothing but "exit 1" in the log. On failure, read the reason back and delete the orphan.
/// Returns the first line worth showing, if any. Pure enough to test: the path is injected.
@discardableResult
func reapFailedPostProcess(outPath: String, fs: FileManager = .default) -> String? {
    let partial = outPath + ".partial"
    defer { try? fs.removeItem(atPath: partial) }
    // Read a head, not the file: a runner can stream megabytes before it dies. Lossy decoding, because a
    // half-written UTF-8 sequence at the cut must not throw the reason away.
    guard let h = FileHandle(forReadingAtPath: partial) else { return nil }
    defer { try? h.close() }
    let head = (try? h.read(upToCount: 8192)) ?? Data()
    guard !head.isEmpty else { return nil }
    let text = String(decoding: head, as: UTF8.self)
    let reason = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .first(where: { !$0.isEmpty })
    return reason.map { String($0.prefix(200)) }
}

func postProcessInvocationFromPrefs(transcriptPath: String) -> String? {
    let mode = effectivePostProcessMode(rawMode: Pref.explicit(Pref.postProcessMode, "MR_POST_PROCESS_MODE"),
                                        shellCmd: Pref.postProcessCommand)
    let runner = SummaryRunner(rawValue: Pref.explicit(Pref.summaryRunner, "MR_SUMMARY_RUNNER")) ?? .claude
    let prompt = effectiveSummaryPrompt(inline: Pref.explicit(Pref.summaryPrompt, "MR_SUMMARY_PROMPT"),
                                        filePath: Pref.explicit(Pref.summaryPromptFile, "MR_SUMMARY_PROMPT_FILE"))
    return postProcessInvocation(mode: mode, runner: runner,
                                 prompt: prompt,
                                 shellCmd: Pref.postProcessCommand,
                                 transcriptPath: transcriptPath,
                                 outDir: Pref.explicit(Pref.summaryOut, "MR_SUMMARY_OUT"))
}

/// Fire-and-forget: a slow or hung command can never block the engine. Runs in a LOGIN shell
/// (`zsh -lc`) so PATH/brew/rc setup apply (agent CLIs like `claude` just work). Output (both
/// streams) is read to EOF BEFORE waiting on exit — reading after would deadlock once the pipe
/// buffer fills. `completion` receives the exit status (or -1 when the launch failed); selftest uses it.
func runPostProcessCommand(_ command: String, completion: ((Int32) -> Void)? = nil) {
    let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cmd.isEmpty else { return }
    DispatchQueue.global(qos: .utility).async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        // `zsh -l` reads .zprofile/.zshenv but NOT .zshrc — where many users export PATH. Prepend the
        // common CLI install dirs so `claude`/`gemini`/`codex` resolve regardless of rc-file layout.
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:\(home)/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do {
            try p.run()
            // A hook whose child keeps the pipe open would pin this thread forever (review finding) —
            // terminate after 15 min; readDataToEndOfFile then unblocks on pipe EOF.
            let killer = DispatchWorkItem { [weak p] in
                guard let p, p.isRunning else { return }
                elog("post-process: timed out after 15 min — terminating")
                p.terminate()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 900, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()   // EOF first, then exit — no pipe deadlock
            p.waitUntilExit()
            killer.cancel()
            // The command redirects its own stdout into `<out>.partial`, so this pipe is usually empty and
            // the reason lives in that file — see reapFailedPostProcess, which the callers use on failure.
            let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            elog("post-process: exit \(p.terminationStatus)" + (s.isEmpty ? "" : " — \(s.prefix(400))"))
            completion?(p.terminationStatus)
        } catch {
            elog("post-process: launch failed — \(error.localizedDescription)")
            completion?(-1)
        }
    }
}

// MARK: - settings window (grouped row-card form, persists to UserDefaults)

/// Scroll-document container whose origin is the TOP (AppKit views are bottom-up by default) —
/// forms in a scroll view should start at the top and grow downward.
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

    static func forLanguage(_ raw: String?) -> TranscriptL10n {
        switch raw.map({ String($0.lowercased().prefix(2)) }) {
        case "ko": return .init(code: "ko", autoTitle: "자동 전사", time: "시각", speech: "발화", model: "모델",
                                audio: "오디오", audioNotKept: "_(보관 안 함)_", meetingLink: "회의 링크",
                                attendees: "참석자", tags: "태그", section: "## 전사 (transcript)")
        case "ja": return .init(code: "ja", autoTitle: "自動文字起こし", time: "時刻", speech: "発話", model: "モデル",
                                audio: "音声", audioNotKept: "_(保存なし)_", meetingLink: "会議リンク",
                                attendees: "参加者", tags: "タグ", section: "## 文字起こし (transcript)")
        default:   return .init(code: "en", autoTitle: "Auto transcript", time: "Time", speech: "Speech", model: "Model",
                                audio: "Audio", audioNotKept: "_(not kept)_", meetingLink: "Meeting link",
                                attendees: "Attendees", tags: "Tags", section: "## Transcript")
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

    func markdown(_ t: TranscriptL10n) -> String {
        """
        # \(day) \(hmStart)–\(hmEnd) — \(title)

        \(t.recordingNote(mine: bodyMine, theirs: bodyTheirs, excludes: excludes))

        - \(t.time): \(day) \(hmStart)–\(hmEnd) (\(t.minutes(mins)))
        - \(t.speech): mic \(String(format: "%.1f", micVoiced))s · sys \(String(format: "%.1f", sysVoiced))s · \(t.model): `\(modelName)`
        \(audioLine)\(meta)
        - \(t.tags): #transcript #auto

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

enum Notifier {
    static func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, err in
            elog("notify: authorization granted=\(granted)\(err.map { " error=\($0)" } ?? "")")
        }
    }
    /// filePath rides in userInfo; clicking the notification opens it (AppController is the delegate).
    static func push(title: String, body: String, filePath: String? = nil, openURL: URL? = nil) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        var info: [String: String] = [:]
        if let filePath { info["file"] = filePath }               // a local path — opened as a file on click
        if let openURL { info["url"] = openURL.absoluteString }   // a web link — kept DISTINCT so a URL is never opened as a path
        if !info.isEmpty { c.userInfo = info }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        ) { err in if let err { elog("notify: add failed: \(err)") } }
    }
}

/// Container for a custom NSMenuItem view that replicates the NATIVE hover behavior a plain view
/// lacks: the selection-material pill behind the row and an inverted (white) label while hovered.
/// AppKit draws that for ordinary items only — a `view`-backed item gets nothing. The view-backed
/// row exists so clicking "Transcribe now" does NOT dismiss the menu (user pick — watch the row's
/// spinner in place). Tracking uses .activeAlways because menu tracking runs in its own event mode.
final class MenuHoverView: NSView {
    private let highlight = NSVisualEffectView()
    var onHover: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]              // stretch with whatever width the menu settles on
        highlight.material = .selection
        highlight.state = .active
        highlight.isEmphasized = true
        highlight.blendingMode = .behindWindow
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 4
        highlight.layer?.cornerCurve = .continuous
        highlight.isHidden = true
        highlight.frame = bounds.insetBy(dx: 5, dy: 0)   // native menus inset the pill ~5 pt
        highlight.autoresizingMask = [.width, .height]
        addSubview(highlight, positioned: .below, relativeTo: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setHover(false)   // a menu reopen must never resurrect last time's highlight
    }

    func setHover(_ inside: Bool) {
        highlight.isHidden = !inside
        onHover?(inside)
    }

    var highlightVisibleForTest: Bool { !highlight.isHidden }
    var trackingReadyForTest: Bool { updateTrackingAreas(); return !trackingAreas.isEmpty }
}

/// "WE stopped the engine" — the user paused (`paused`) OR the schedule parked it off-hours
/// (`schedulePaused`). Clicking Resume in either state resumes/overrides and records now. This is the
/// ONE decision behind the tray toggle: its label, its enablement, and what a click does all route
/// through here, so they can't disagree (the schedule-paused Resume no-op was two of them
/// disagreeing — the click branch resumed only `if paused`). Pure + selftested.
func togglePauseShouldResume(paused: Bool, schedulePaused: Bool) -> Bool { paused || schedulePaused }

/// Whether the tray's Pause/Resume item should be clickable: enabled while stopped-by-us (so Resume
/// works, incl. off-hours) or while an engine is recording (so Pause works). Only true idle greys it
/// out. Pure.
func pauseItemEnabled(paused: Bool, schedulePaused: Bool, hasEngine: Bool) -> Bool {
    togglePauseShouldResume(paused: paused, schedulePaused: schedulePaused) || hasEngine
}

/// The two CAPTURE grants that gate recording are satisfied (System Audio + Microphone). Neutral
/// predicate shared by `allPermissionsGranted()` and the "Grant permissions…" hide logic — Calendar is
/// optional (titling) and deliberately excluded so a user who declined it isn't nagged. Pure + selftested.
func captureGrantsSatisfied(audioGranted: Bool, micGranted: Bool) -> Bool { audioGranted && micGranted }

/// A directory picker on a menu-bar (`.accessory`) app must present as a SHEET on a VISIBLE window,
/// or a bare `runModal()` opens behind everything (the "Choose… did nothing" bug). Fall back to
/// activate-then-runModal only when there's no visible window to host a sheet. Pure + selftested.
enum DirPickerPresentation: Equatable { case sheet, activateAndRunModal }
func dirPickerPresentation(hasVisibleWindow: Bool) -> DirPickerPresentation {
    hasVisibleWindow ? .sheet : .activateAndRunModal
}

/// The clickable URL for the "update available" alert, or nil for no button. Homebrew installs get no
/// button (they upgrade via `brew`). Otherwise the release URL — but ONLY if it is https (never let a
/// surprise API payload open a `file:` / `javascript:` / custom-scheme URL), falling back to the
/// hardcoded https releases page when the API url is missing/blank/unsafe. Pure + selftested.
func updateAlertOpenURL(installedViaBrew: Bool, htmlURL: String?, releasesURL: String) -> URL? {
    guard !installedViaBrew else { return nil }
    for s in [htmlURL, releasesURL] {
        if let s, let u = URL(string: s), u.scheme?.lowercased() == "https" { return u }
    }
    return nil
}

/// A small rounded-tile vendor badge (solid brand color + white SF Symbol) for Settings section headers
/// and picker items — at-a-glance identity for each engine/runner. NOT a trademarked logo: a
/// self-contained, self-signed app can't embed those, so this is a tasteful brand-colored mark instead.
func vendorBadge(_ symbol: String, _ color: NSColor, side: CGFloat = 18) -> NSImage {
    let glyphCfg = NSImage.SymbolConfiguration(pointSize: side * 0.56, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(glyphCfg)
    let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        let body = rect.insetBy(dx: 0.5, dy: 0.5)
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(roundedRect: body, xRadius: body.width * 0.28, yRadius: body.width * 0.28).addClip()
        color.setFill(); body.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        if let glyph {
            let g = glyph.size
            glyph.draw(in: NSRect(x: (side - g.width)/2, y: (side - g.height)/2, width: g.width, height: g.height))
        }
        return true
    }
    img.isTemplate = false
    return img
}

/// macrec's menu-bar mark: the waveform-with-mic glyph (the old "transcribe" tray icon the user likes)
/// as a menu-bar TEMPLATE so it adapts to the light/dark menu bar — no colored tile (user: drop the blue
/// background). Voice tints it light orange; paused/idle dims the same mark (maccal-style) so it reads
/// inactive. Rendered at the glyph's NATURAL aspect (waveform-mic is wider than tall — a square box clipped it).
func brandMarkImage(side: CGFloat, recording: Bool, voice: Bool) -> NSImage {
    let lightOrange = NSColor.systemOrange.blended(withFraction: 0.35, of: .white) ?? .systemOrange
    let glyphCfg = NSImage.SymbolConfiguration(pointSize: side * 0.78, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [voice ? lightOrange : .white]))
    let glyph = NSImage(systemSymbolName: "waveform.badge.mic", accessibilityDescription: "macrec")?
        .withSymbolConfiguration(glyphCfg)
    let sz = glyph?.size ?? NSSize(width: side, height: side)   // natural aspect, not forced square
    let img = NSImage(size: sz, flipped: false) { rect in
        // paused/idle draws the same mark at 45% so it reads inactive (maccal-style). `fraction` is the
        // reliable opacity knob for NSImage.draw (cgContext.setAlpha didn't take).
        glyph?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: recording ? 1.0 : 0.45)
        return true
    }
    img.isTemplate = !voice   // template adapts to the light/dark menu bar; the voice tint keeps its color
    return img
}

/// Headless guard: the brand mark actually draws (not an all-transparent image — the "shipped visually
/// destroyed" class of bug). Renders to an offscreen bitmap and checks a meaningful fraction is opaque.
func brandMarkHasContent(recording: Bool, voice: Bool) -> Bool {
    let side: CGFloat = 18, scale = 4
    let px = Int(side) * scale
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
    rep.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    brandMarkImage(side: side, recording: recording, voice: voice).draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    var opaque = 0
    for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
        if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { opaque += 1 }
    }}
    return opaque > px * px / 10   // ≥ ~10% drawn
}

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var engine: RecordingEngine?
    private var stopTask: Task<Void, Never>?   // in-flight engine stop (pause) — resume/restart await it so
                                               // two capture pipelines never overlap on the shared audio state
    private var voiceTimer: Timer?             // ~1 Hz poll for the voice-activity tray tint
    private var schedTimer: Timer?             // ~30 s recording-schedule enforcement
    private var notifyWhenTranscribed = false  // armed by "Transcribe now" — the menu closed, push the outcome
    private var lastTranscriptURL: URL?        // most recent saved transcript (notification click opens it)
    private var flushBusy = false              // one manual flush at a time; the row spinner shows progress
    private var flushGeneration = 0            // failsafe-timeout token (a new flush invalidates old timers)
    private var transcribeBtn: NSButton!               // "Transcribe now" row (view-backed: menu stays open)
    private let menuRowSpinner = NSProgressIndicator() // replaces the row's icon while the flush runs
    private var transcribeRowTitle = "Transcribe now"  // flashes the outcome ("No speech found") briefly
    private var rowHovered = false                     // hover restyle must not clobber a flashed title
    private var spinStartedAt: TimeInterval = 0        // enforce a visible minimum spin (see spinnerHold)
    private var schedulePaused = false         // the SCHEDULE stopped the engine (vs the user's `paused`)
    private var scheduleOverrideUntil: Date?   // manual Pause/Resume wins until this boundary passes
    private var startTask: Task<Void, Never>?  // in-flight engine start — stops must wait for it
    private var voiceShown = false
    private var lastVoiceAt: TimeInterval = 0
    private var statusLine: NSMenuItem!
    private var levelItem: NSMenuItem!
    private var lastSavedLine: NSMenuItem!
    private var modelLine: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var liveItem: NSMenuItem?   // "Live captions" toggle (macOS 26+)
    private var summaryLine: NSMenuItem!   // what post-processing is doing, refreshed when the menu opens
    private var digestLine: NSMenuItem!
    private var pendingSummaryAction: SummaryRowAction = .none
    private var digestInFlight = false   // the 30 s tick must not launch a second digest
    private var grantItem: NSMenuItem?  // "Grant permissions…" — shown ONLY while a permission is missing
    private var paused = false
    private var didAutoPrompt = false   // only auto-open the permission prompts/Settings once per launch
    private var checkingForUpdates = false   // a manual update check is in flight — don't stack modal alerts
    private var settingsWC: SettingsWindowController?
    private var levelTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: if a copy is already running (the LaunchAgent one), just tell it to open
        // its menu and quit this launch — so clicking the app in /Applications opens the tray menu.
        let bid = Bundle.main.bundleIdentifier ?? "com.ikhoon.macrec"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(
                .init("com.ikhoon.macrec.openMenu"), object: nil, deliverImmediately: true)
            NSApp.terminate(nil); return
        }
        buildMenu()
        let vt = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.pollVoice() }
        RunLoop.main.add(vt, forMode: .common)   // .common so the tint updates while menus track too
        voiceTimer = vt
        let st = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.checkSchedule(); self?.maybeRunDailyDigest(); self?.maybeCheckForUpdates() }   // timer runs in .common; engine state is main-confined
        }
        RunLoop.main.add(st, forMode: .common)
        schedTimer = st
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.ikhoon.macrec.openMenu"), object: nil, queue: .main
        ) { [weak self] _ in self?.openMenu() }
        UNUserNotificationCenter.current().delegate = self   // click a completion push → open the file
        CalendarLookup.requestAccess()   // one-time Calendar prompt (for titling transcripts)
        setupModelDownload()             // first-run: fetch the large model, show progress in the menu
        LoginItem.autoEnableOnceIfDistributed()   // distributed app: enable 24/7 autostart on first run
        startEngineRespectingSchedule()           // a 23:00 login with a 10-19h schedule must NOT record
        installStopHandler { [weak self] in
            // `engine` is main-confined (voice poll, menu actions read it there) — the signal source
            // fires on its own queue, so hop to main before touching it (review finding: racy mutation).
            DispatchQueue.main.async {
                self?.stopEngineSync()
                NSApp.terminate(nil)
            }
        }
    }

    private func setIcon(recording: Bool, voice: Bool = false) {
        // The macrec menu-bar mark (waveform-mic glyph, template) — adapts to light/dark, no colored tile
        // (user: drop the blue background). Voice tints light orange; paused/idle dims it (maccal-style).
        let img = brandMarkImage(side: 18, recording: recording, voice: voice)
        statusItem.button?.image = img
        statusItem.length = ceil(img.size.width) + 4
        if Pref.bool("trayDebug", "MR_TRAY_DEBUG", false) {
            elog("icon set (recording=\(recording), voice=\(voice)), length=\(statusItem.length)")
        }
    }

    /// Poll the engine's recent input levels (~1 Hz, negligible) and reflect "voice being picked up"
    /// in the tray glyph. 2 s hysteresis so normal speech pauses don't flicker the icon.
    private func pollVoice() {
        guard let eng = engine, !paused else {
            if voiceShown { voiceShown = false; setIcon(recording: engine != nil && !paused) }
            return
        }
        let (mic, sys) = eng.liveLevels()
        let now = ProcessInfo.processInfo.systemUptime
        if max(mic, sys) > 0.02 { lastVoiceAt = now }   // ≈ one meter dot — speech, not room noise
        let active = now - lastVoiceAt < 2.0
        if active != voiceShown { voiceShown = active; setIcon(recording: true, voice: active) }
    }

    private func item(_ title: String, _ sel: Selector, _ key: String = "", symbol: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key); i.target = self
        if !symbol.isEmpty { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        return i
    }

    /// The two CAPTURE grants that gate recording are in place (System Audio + Microphone) — used to
    /// hide "Grant permissions…" when there's nothing recording-critical left to grant (re-checked each
    /// menu open, so allowing them elsewhere clears it). Calendar is optional and intentionally excluded.
    private func allPermissionsGranted() -> Bool {
        captureGrantsSatisfied(audioGranted: audioCaptureAuthorized(), micGranted: micAuthorized())
    }

    /// Grey out "Pause" when nothing is recording to pause (off-hours / idle); the menu re-validates
    /// each time it opens. "Resume" (paused) stays enabled. Other items are unaffected.
    /// The menu auto-enables its items, so AppKit calls this AFTER menuWillOpen and it has the last word.
    /// Setting `isEnabled` directly on a target/action row is silently undone here.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === toggleItem { return pauseItemEnabled(paused: paused, schedulePaused: schedulePaused, hasEngine: engine != nil) }
        if menuItem === summaryLine { return pendingSummaryAction != .none }
        return true
    }

    private func buildMenu() {
        setIcon(recording: false)
        let menu = NSMenu()
        // Transcribe now keeps the menu OPEN while the status line swaps between
        // strings of different lengths ("● Transcribing…" → "● No speech —
        // skipped" → "● Recording · mic + system audio"). An NSMenu re-measures
        // its width per change, so the open menu visibly jiggles. Pin a minimum
        // width sized to the longest routine status so text swaps never resize it.
        let widestStatus = "⚠ Grant System Audio Recording + Microphone to macrec"
        let statusFont = NSFont.menuFont(ofSize: 0)
        menu.minimumWidth = (widestStatus as NSString)
            .size(withAttributes: [.font: statusFont]).width + 36 // item insets
        // About on top (macOS convention), then a divider.
        menu.addItem(item("About macrec", #selector(showAbout), symbol: "info.circle"))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates), symbol: "arrow.triangle.2.circlepath"))
        menu.addItem(.separator())
        // Live status rows (disabled — informational; they carry their own inline status glyphs).
        statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: ""); statusLine.isEnabled = false
        levelItem = NSMenuItem(title: "🎤 —   🔊 —", action: nil, keyEquivalent: ""); levelItem.isEnabled = false
        lastSavedLine = NSMenuItem(title: "", action: nil, keyEquivalent: ""); lastSavedLine.isEnabled = false; lastSavedLine.isHidden = true
        modelLine = NSMenuItem(title: "", action: nil, keyEquivalent: ""); modelLine.isEnabled = false; modelLine.isHidden = true
        // Post-processing used to leave no trace at all, so a working pipeline read as a broken one.
        summaryLine = NSMenuItem(title: "", action: #selector(revealLastSummary), keyEquivalent: "")
        summaryLine.target = self
        digestLine = NSMenuItem(title: "", action: nil, keyEquivalent: ""); digestLine.isEnabled = false
        menu.addItem(statusLine); menu.addItem(levelItem); menu.addItem(lastSavedLine); menu.addItem(modelLine)
        menu.addItem(summaryLine); menu.addItem(digestLine)
        menu.addItem(.separator())
        // Transcribe now — view-backed so the click does NOT dismiss the menu (user pick, round 2:
        // stay open and watch the row's spinner in place). MenuHoverView supplies the native-style
        // hover pill AppKit withholds from view-backed items; the completion push still fires for
        // whenever the menu IS closed while a flush runs.
        let tItem = NSMenuItem()
        let tView = MenuHoverView(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        let tBtn = NSButton(title: "Transcribe now", target: self, action: #selector(flushNow))
        tBtn.isBordered = false; tBtn.alignment = .left
        transcribeBtn = tBtn
        styleTranscribeRow()
        tView.onHover = { [weak self] hovered in
            self?.rowHovered = hovered
            self?.styleTranscribeRow()
        }
        tBtn.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "Transcribe now")
        tBtn.imagePosition = .imageLeading
        // AppKit's default image↔title gap matches the standard imaged items; a small left inset
        // lines the icon up with them.
        tBtn.frame = NSRect(x: 14, y: 1, width: 221, height: 20)
        tBtn.autoresizingMask = [.width]
        menuRowSpinner.style = .spinning
        menuRowSpinner.controlSize = .small
        menuRowSpinner.isDisplayedWhenStopped = false
        menuRowSpinner.frame = NSRect(x: 13, y: 3, width: 16, height: 16)   // sits where the icon was
        tView.addSubview(tBtn); tView.addSubview(menuRowSpinner); tItem.view = tView
        menu.addItem(tItem)
        toggleItem = item("Pause", #selector(togglePause), symbol: "pause.circle"); menu.addItem(toggleItem)
        if #available(macOS 26, *) {   // real-time caption overlay (on-device SpeechAnalyzer)
            let li = item("Live captions", #selector(toggleLive), symbol: "captions.bubble")
            li.state = LiveCaptions.shared.active ? .on : .off
            liveItem = li; menu.addItem(li)
        }
        menu.addItem(.separator())
        let grant = item("Grant permissions…", #selector(grantPermissions), symbol: "hand.raised")
        grant.isHidden = allPermissionsGranted()   // only surfaces when audio or mic is still missing
        grantItem = grant
        menu.addItem(grant)
        menu.addItem(item("Settings…", #selector(openSettings), ",", symbol: "gearshape"))
        menu.addItem(item("Open transcripts folder", #selector(openTranscripts), "o", symbol: "folder"))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), "q", symbol: "power"))
        menu.delegate = self
        statusItem.menu = menu
    }

    // Live input meter — only updates while the menu is open (cheap, and answers "is it working?").
    /// The summary/digest rows, re-derived from prefs and live status every time the menu opens.
    private func refreshPostProcessRows() {
        let mode = effectivePostProcessMode(rawMode: Pref.explicit(Pref.postProcessMode, "MR_POST_PROCESS_MODE"),
                                            shellCmd: Pref.postProcessCommand)
        let (live, lastOut) = SummaryStatus.shared.snapshot
        let activity: SummaryActivity = mode == .off ? .off : live
        let hm = DateFormatter(); hm.locale = Locale(identifier: "en_US_POSIX"); hm.dateFormat = "HH:mm"
        summaryLine.title = summaryMenuTitle(activity) { hm.string(from: $0) }
        // Enablement is decided ONCE, in validateMenuItem, from this same action — assigning isEnabled
        // here would be overwritten by AppKit's validation pass.
        pendingSummaryAction = summaryRowAction(activity, lastOutput: lastOut)

        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        digestLine.title = digestMenuTitle(enabled: Pref.bool(Pref.dailyDigest, "MR_DAILY_DIGEST", false),
                                           dueTime: Pref.str(Pref.dailyDigestTime, "MR_DAILY_DIGEST_TIME", "20:00"),
                                           lastRun: Pref.explicit(Pref.dailyDigestLastRun, ""),
                                           today: day.string(from: Date()))
    }

    /// Drives the REAL buildMenu + menuWillOpen and reports the two post-process rows. A deleted call to
    /// `refreshPostProcessRows` or a renamed selector then leaves the rows frozen and turns the selftest
    /// red — asserting that a function merely EXISTS proves nothing about it being wired.
    func postProcessRowsAfterMenuOpenForTest() -> (summary: String, digest: String, enabled: Bool)? {
        buildMenu()
        guard let menu = statusItem.menu else { return nil }
        menuWillOpen(menu)
        // The menu auto-enables its items: AppKit re-validates every target/action item AFTER
        // menuWillOpen, so reading `isEnabled` here without an update() pass reads back the value we
        // just assigned, not the one the user sees. Drive the real validation.
        menu.update()
        menu.cancelTracking()
        guard let s = summaryLine, let d = digestLine else { return nil }
        return (s.title, d.title, s.isEnabled)
    }

    /// Clicking the summary row: reveal what it wrote, or explain why it didn't. Never nothing.
    @objc private func revealLastSummary() {
        switch pendingSummaryAction {
        case .none:
            break
        case .reveal(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .explain(let file, let reason):
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Summary failed for \(file)"
            a.informativeText = reason ?? "The summary runner exited with an error and wrote nothing. "
                + "Check the runner in Settings › Summaries."
            a.alertStyle = .warning
            a.addButton(withTitle: "Open Settings")
            a.addButton(withTitle: "Close").keyEquivalent = "\u{1b}"
            if a.runModal() == .alertFirstButtonReturn { openSettings() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Opt-in tray diagnostics (`defaults write com.ikhoon.macrec.prefs trayDebug -bool true`): the
        // menu anchors to the status button's WINDOW — if it ever opens detached (screen edge, the
        // reported multi-display bug), this frame is the evidence. The probe file additionally lets a
        // remote diagnostic open+auto-close the menu (`touch /tmp/macrec-tray-probe && open -a macrec`).
        if Pref.bool("trayDebug", "MR_TRAY_DEBUG", false) {
            if let win = statusItem.button?.window {
                let screens = NSScreen.screens.map { "(\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))×\(Int($0.frame.height)))" }.joined(separator: " ")
                elog("tray-diag open: btnWin=\(NSStringFromRect(win.frame)) onScreen=\(NSStringFromRect(win.screen?.frame ?? .zero)) mouse=\(NSStringFromPoint(NSEvent.mouseLocation)) len=\(statusItem.length) vis=\(statusItem.isVisible) screens=\(screens)")
            }
            if FileManager.default.fileExists(atPath: "/tmp/macrec-tray-probe") {
                try? FileManager.default.removeItem(atPath: "/tmp/macrec-tray-probe")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { menu.cancelTracking() }
            }
        }
        updateLevels()
        // Reflect the live-captions state in case it was turned off by closing the floating panel.
        if #available(macOS 26, *) { liveItem?.state = LiveCaptions.shared.active ? .on : .off }
        // Hide "Grant permissions…" once both grants are in place (re-checked each open — the user may
        // have just allowed them in System Settings). It reappears if a grant is ever revoked.
        grantItem?.isHidden = allPermissionsGranted()
        refreshPostProcessRows()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.updateLevels() }
        RunLoop.main.add(t, forMode: .eventTracking)   // fires while the menu is tracking
        levelTimer = t
    }
    func menuDidClose(_ menu: NSMenu) { levelTimer?.invalidate(); levelTimer = nil }

    private func meter(_ v: Float) -> String {
        let n = min(8, max(0, Int(min(1, v * 4) * 8)))   // speech peaks ~0.1–0.5 → some gain
        // ●/○ are a same-width pair (▰/▱ rendered at different sizes in the menu font).
        return String(repeating: "●", count: n) + String(repeating: "○", count: 8 - n)
    }

    private func updateLevels() {
        guard let eng = engine, !paused else { levelItem.title = "🎤 —   🔊 —"; return }
        let (mic, sys) = eng.liveLevels()
        levelItem.title = "🎤 \(meter(mic))  🔊 \(meter(sys))"
    }

    private func refresh(_ status: String) {
        statusLine?.title = status
        // Label + icon route through the SAME decision as the click and the enablement, so they can't
        // disagree (see togglePauseShouldResume).
        let stoppedByUs = togglePauseShouldResume(paused: paused, schedulePaused: schedulePaused)
        toggleItem?.title = stoppedByUs ? "Resume" : "Pause"
        toggleItem?.image = NSImage(systemSymbolName: stoppedByUs ? "play.circle" : "pause.circle", accessibilityDescription: nil)
    }

    /// First-run model download (the large model is too big to bundle). Surfaces progress in the menu;
    /// the engine transcribes automatically once the file lands (it re-checks per segment).
    private func setupModelDownload() {
        ModelStore.shared.onProgress = { [weak self] p in
            guard let self = self else { return }
            if p >= 1.0 {
                self.modelLine.title = "✓ Model ready"; self.modelLine.isHidden = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.modelLine.isHidden = true }
            } else if p < 0 {
                self.modelLine.title = "⚠ Model download failed — retries on restart"; self.modelLine.isHidden = false
            } else {
                self.modelLine.title = String(format: "⤓ Downloading model… %.0f%%", p * 100); self.modelLine.isHidden = false
            }
        }
        if ModelStore.shared.isReady {
            modelLine.isHidden = true
        } else {
            modelLine.title = "⤓ Preparing model…"; modelLine.isHidden = false
        }
        ModelStore.shared.ensure()
    }

    private func startEngine() {
        let eng = RecordingEngine(cfg: EngineConfig.load())   // reload prefs each start so settings apply
        eng.onSegmentResult = { [weak self] msg in
            DispatchQueue.main.async {
                if self?.paused == false { self?.statusLine.title = "● \(msg)" }
                self?.pushFlushOutcomeIfNeeded(msg)
            }
        }
        eng.onTranscriptURL = { [weak self] url in
            DispatchQueue.main.async { self?.lastTranscriptURL = url }   // before onTranscriptSaved (FIFO)
        }
        eng.onTranscriptSaved = { [weak self] msg in
            DispatchQueue.main.async {
                self?.lastSavedLine.title = "✓ \(msg)"; self?.lastSavedLine.isHidden = false
                if self?.paused == false { self?.statusLine.title = "● Recording · mic + system audio" }
                self?.pushFlushOutcomeIfNeeded(msg)
            }
        }
        engine = eng
        startTask = Task {   // kept so stop paths can AWAIT the start — stopping mid-start would
            do {             // no-op (nothing to tear down yet) and orphan a live capture pipeline
                try await eng.start()
                await MainActor.run {
                    guard self.engine === eng else { return }   // stopped while starting — don't repaint
                    self.paused = false; self.setIcon(recording: true); self.refresh("● Recording · mic + system audio")
                }
            } catch {
                await MainActor.run {
                    self.engine = nil; self.setIcon(recording: false)
                    self.refresh("⚠ Grant System Audio Recording + Microphone to macrec")
                    if !self.didAutoPrompt { self.didAutoPrompt = true; self.grantPermissions() }  // fire prompts + open Settings once
                }
            }
        }
    }

    /// Start the engine unless the schedule says these are off-hours — in which case park in
    /// schedule-pause WITHOUT starting. Gating the start (instead of start-then-stop) is what keeps
    /// stop() from racing an in-flight start() at launch / settings-save time.
    private func startEngineRespectingSchedule() {
        if RecordSchedule.fromPrefs.isActive(at: Date()) {
            if !paused && engine == nil { startEngine() }
        } else {
            schedulePaused = true
            setIcon(recording: false)
            refresh("⏸ Off-hours (schedule)")
        }
    }

    @objc private func flushNow() {
        guard engine != nil, !paused, !flushBusy else { return }   // busy = one flush at a time
        notifyWhenTranscribed = true   // outcome arrives as a push (the menu may be closed by then)
        Notifier.requestAuth()         // no-op after the user answered the first prompt
        showFlushSpinner()             // the row's icon slot spins until the outcome lands
        engine?.flushNow()
        refresh("● Transcribing now…")
    }

    /// One push per armed "Transcribe now": the first TERMINAL status (saved / no speech / failed)
    /// consumes the flag; intermediate ones ("Transcribing…") don't. The reveal is held so the
    /// spinner stays visible ≥1 s — a "no speech" outcome lands in ~0.3 s, and a click that shows
    /// nothing reads as a dead button (user report). The row then flashes the outcome in place.
    private func pushFlushOutcomeIfNeeded(_ status: String) {
        guard notifyWhenTranscribed, let o = flushOutcome(for: status) else { return }
        notifyWhenTranscribed = false
        let file = status.hasPrefix("Saved: ") ? lastTranscriptURL?.path : nil
        let gen = flushGeneration
        let hold = spinnerHold(elapsed: ProcessInfo.processInfo.systemUptime - spinStartedAt)
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard let self, self.flushGeneration == gen else { return }
            self.hideFlushSpinner()
            self.flashTranscribeRow(o.title)   // in-menu answer, e.g. "No speech found"
            Notifier.push(title: o.title, body: o.body, filePath: file)
        }
    }

    /// Menu-item look for the Transcribe-now row (borderless buttons default to the gray button
    /// style), flipping to white while the hover pill shows — and rendering whatever the current
    /// row title is, so a flashed outcome survives hover changes.
    private func styleTranscribeRow() {
        let fg: NSColor = rowHovered ? .selectedMenuItemTextColor : .labelColor
        transcribeBtn.attributedTitle = NSAttributedString(
            string: transcribeRowTitle,
            attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: fg])
        transcribeBtn.contentTintColor = fg
    }

    /// Show the flush outcome in the row itself for a moment ("No speech found"), then restore
    /// "Transcribe now" — the menu stays open on click, so the answer belongs where the user is looking.
    private func flashTranscribeRow(_ text: String) {
        transcribeRowTitle = text
        styleTranscribeRow()
        let gen = flushGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.flushGeneration == gen else { return }   // a newer flush owns the row
            self.transcribeRowTitle = "Transcribe now"
            self.styleTranscribeRow()
        }
    }

    /// While a manual flush transcribes, the ROW shows the progress: its icon slot becomes a small
    /// spinner. The tray glyph stays put — a changing menu-bar icon read as noise (user pick).
    private func showFlushSpinner() {
        guard !flushBusy else { return }
        flushBusy = true
        flushGeneration += 1
        spinStartedAt = ProcessInfo.processInfo.systemUptime
        // A transparent placeholder the SAME SIZE as the icon: with image=nil the title slides left
        // into the icon slot and renders UNDER the spinner (user report: "UI broke while spinning").
        let iconSize = transcribeBtn.image?.size ?? NSSize(width: 16, height: 16)
        transcribeBtn.image = NSImage(size: iconSize)     // no representations = draws nothing
        transcribeBtn.isEnabled = false           // no double-flush while one is running
        menuRowSpinner.startAnimation(nil)
        // Failsafe: whisper on a long segment takes minutes, but a lost outcome (engine swapped out
        // mid-flush) must not leave the row spinning forever.
        let gen = flushGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 15 * 60) { [weak self] in
            guard let self, self.flushBusy, self.flushGeneration == gen else { return }
            elog("menu: flush spinner timed out — restoring the row")
            self.hideFlushSpinner()
        }
    }

    private func hideFlushSpinner() {
        guard flushBusy else { return }
        flushBusy = false
        menuRowSpinner.stopAnimation(nil)
        transcribeBtn.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "Transcribe now")
        transcribeBtn.isEnabled = true
    }

    @objc private func togglePause() {
        // A manual choice beats the schedule until the next boundary — stored as the boundary's
        // TIMESTAMP so it still expires when the Mac slept across it (nil = schedule never flips).
        scheduleOverrideUntil = RecordSchedule.fromPrefs.nextBoundary(after: Date())
        // Resume covers BOTH states WE own: a manual pause and a schedule-parked (off-hours) engine.
        // The bug: schedule-pause (paused == false) fell through to the else and manually PAUSED
        // instead of resuming. Same decision the label/enablement use — capture before clearing.
        let wasStopped = togglePauseShouldResume(paused: paused, schedulePaused: schedulePaused)
        schedulePaused = false
        if wasStopped {
            paused = false; refresh("Resuming…")
            resumeEngineAfterStop()
        } else {
            paused = true; setIcon(recording: false); refresh("⏸ Paused")
            if let eng = engine {
                engine = nil
                let starting = startTask
                stopTask = Task { if let starting { _ = await starting.value }; await eng.stop() }
            }
        }
    }

    /// Start the engine once any in-flight stop has finished (see togglePause for why waiting matters).
    private func resumeEngineAfterStop() {
        // Pause's stop is fire-and-forget (instant UI); a quick resume must WAIT for it, or two
        // capture pipelines briefly overlap (two mic queues + two taps on the shared audio state).
        // stopTask stays set until the stop has truly finished — clearing it on read would let a
        // pause→resume→pause→resume flurry start an engine while the first stop is still in flight.
        let stopping = stopTask
        Task {
            if let stopping { _ = await stopping.value }
            await MainActor.run {
                if self.stopTask == stopping { self.stopTask = nil }
                if !self.paused && !self.schedulePaused && self.engine == nil { self.startEngine() }
            }
        }
    }

    /// L3 of the pipeline (PIPELINE.md): once the configured time passes, digest the day's meeting
    /// summaries into Daily/YYYY-MM/YYYY-MM-DD.md. Rides the same 30 s tick as the schedule; the
    /// last-run marker (not a timer) makes a slept-through deadline catch up on wake. The marker is
    /// set when the run LAUNCHES — a failed run logs and retries tomorrow rather than every 30 s.
    private func maybeRunDailyDigest() {
        guard Pref.bool(Pref.dailyDigest, "MR_DAILY_DIGEST", false) else { return }
        let now = Date()
        let time = Pref.str(Pref.dailyDigestTime, "MR_DAILY_DIGEST_TIME", "20:00")
        guard dailyDigestDue(now: now, time: time, lastRun: Pref.explicit(Pref.dailyDigestLastRun, "")) else { return }
        let dayF = DateFormatter(); dayF.locale = Locale(identifier: "en_US_POSIX"); dayF.dateFormat = "yyyy-MM-dd"
        let day = dayF.string(from: now)
        // The 30 s tick must not launch a second digest, but a FAILED one has to retry — so the in-flight
        // guard is in memory and the persistent "done" marker is written only once the runner succeeds.
        // Writing the marker up front meant a login error at 20:00 silently cost the whole day.
        guard !digestInFlight else { return }
        digestInFlight = true
        // Every early return below must clear the flag, or the digest never runs again this process.
        var launched = false
        defer { if !launched { digestInFlight = false } }
        let cfg = EngineConfig.load()
        let fm = FileManager.default
        let month = String(day.prefix(7))
        let tDir = cfg.transcriptsDir.appendingPathComponent(month)
        let transcripts = ((try? fm.contentsOfDirectory(atPath: tDir.path)) ?? [])
            .filter { $0.hasSuffix(".md") }.map { tDir.appendingPathComponent($0).path }
        let sumPref = Pref.explicit(Pref.summaryOut, "MR_SUMMARY_OUT")
        let sDir = sumPref.isEmpty ? tDir.path
                                   : ((sumPref as NSString).expandingTildeInPath + "/" + month)
        let summaries = ((try? fm.contentsOfDirectory(atPath: sDir)) ?? [])
            .filter { $0.hasSuffix(".md") }.map { sDir + "/" + $0 }
        // The digest is promoted with `mv`, which overwrites whatever sits at the destination. A name
        // template that resolves onto an existing transcript/summary would silently destroy it.
        let existingNotes = Set(transcripts.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let out = dailyDigestOutputPath(day: day,
                                        outDir: Pref.explicit(Pref.dailyDigestOut, "MR_DAILY_DIGEST_OUT"),
                                        summaryOutDir: sumPref, transcriptsDir: cfg.transcriptsDir.path,
                                        nameTemplate: Pref.explicit(Pref.dailyDigestName, "MR_DAILY_DIGEST_NAME"))
        func retire(_ outcome: DigestOutcome) {
            if digestMarksDayDone(outcome) { Pref.d.set(day, forKey: Pref.dailyDigestLastRun) }
        }
        guard !existingNotes.contains(URL(fileURLWithPath: out).standardizedFileURL.path) else {
            elog("digest: \(out) is an existing transcript — refusing to overwrite it")
            retire(.wouldOverwrite)   // retrying changes nothing until the user edits the name
            Notifier.push(title: "Daily digest skipped",
                          body: "The file name resolves onto an existing note (\(URL(fileURLWithPath: out).lastPathComponent)). "
                              + "Change it in Settings › Summaries › File name.")
            return
        }
        // Exclude the digest itself: it lands in a folder we just scanned and shares the day prefix.
        let inputs = dailyDigestInputs(day: day, transcripts: transcripts, summaries: summaries, excluding: out)
        guard !inputs.isEmpty else { elog("digest: no meetings on \(day) — skipping"); retire(.nothingToDo); return }
        let runner = SummaryRunner(rawValue: Pref.explicit(Pref.summaryRunner, "MR_SUMMARY_RUNNER")) ?? .claude
        let inline = effectiveSummaryPrompt(inline: Pref.explicit(Pref.dailyPrompt, "MR_DAILY_DIGEST_PROMPT"),
                                            filePath: Pref.explicit(Pref.dailyPromptFile, "MR_DAILY_DIGEST_PROMPT_FILE"))
        let prompt = inline.isEmpty ? defaultDailyDigestPrompt : inline
        guard let cmd = dailyDigestInvocation(runner: runner, prompt: prompt,
                                              inputs: inputs, outPath: out) else { retire(.nothingToDo); return }
        elog("digest: \(day) — \(inputs.count) inputs → \(out)")
        SummaryStatus.shared.started("daily digest \(day)")
        launched = true
        runPostProcessCommand(cmd) { [weak self] status in
            if status == 0 {
                // Only a SUCCESSFUL run retires the day; a failure retries on the next tick.
                elog("digest: \(day) finished (exit 0)")
                if digestMarksDayDone(.wrote) { Pref.d.set(day, forKey: Pref.dailyDigestLastRun) }
                SummaryStatus.shared.finished("daily digest \(day)", at: Date(), output: out)
                Notifier.push(title: "Daily digest ready", body: "\(day) — \(inputs.count) meetings", filePath: out)
            } else {
                let why = reapFailedPostProcess(outPath: out)
                // The reason belongs in the LOG too, not only in a notification the user may miss.
                elog("digest: \(day) failed (exit \(status))" + (why.map { " — \($0)" } ?? " — no output"))
                SummaryStatus.shared.failed("daily digest \(day)", at: Date(), reason: why)
                Notifier.push(title: "Daily digest failed",
                              body: why ?? "The summary command exited with code \(status) — check Settings › Summaries.")
            }
            DispatchQueue.main.async { self?.digestInFlight = false }
        }
    }

    /// Enforce the recording schedule (~30 s tick). A manual Pause/Resume overrides until the next
    /// schedule boundary — an expiry TIMESTAMP, so it lapses even if the Mac slept across it.
    private func checkSchedule() {
        let sched = RecordSchedule.fromPrefs
        let now = Date()
        if let until = scheduleOverrideUntil, now >= until { scheduleOverrideUntil = nil }
        if !sched.enabled || scheduleOverrideUntil != nil {
            if schedulePaused {   // schedule turned off (or overridden) while it held the engine
                schedulePaused = false
                if !paused { refresh("Resuming…"); resumeEngineAfterStop() }
            }
            return
        }
        if !sched.isActive(at: now), !paused, !schedulePaused, engine != nil {
            schedulePaused = true
            setIcon(recording: false)
            refresh("⏸ Off-hours (schedule)")
            if let eng = engine {
                engine = nil
                let starting = startTask
                stopTask = Task { if let starting { _ = await starting.value }; await eng.stop() }
            }
        } else if sched.isActive(at: now), schedulePaused {
            schedulePaused = false
            refresh("Resuming…")
            resumeEngineAfterStop()
        }
    }

    /// Toggle the real-time caption overlay (macOS 26+ SpeechAnalyzer). The saved whisper transcript
    /// is unaffected — this is a live view only.
    @available(macOS 26, *)
    @objc private func toggleLive() {
        LiveCaptions.shared.toggle()
        liveItem?.state = LiveCaptions.shared.active ? .on : .off
    }

    /// Fire the permission prompts inline. System Audio Recording, Microphone and Calendar all show
    /// a normal consent popup on macOS 15+ (kTCCServiceAudioCapture prompts like the mic does), so no
    /// Settings trip is needed for a first grant. If audio is still denied afterwards (user clicked
    /// Deny earlier → no re-prompt), deep-link to the Privacy pane so they can toggle it.
    @objc private func grantPermissions() {
        NSApp.activate(ignoringOtherApps: true)
        _ = requestPermissions()          // System Audio Recording prompt + Microphone popup
        CalendarLookup.requestAccess()    // Calendar popup
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !audioCaptureAuthorized() else { return }
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                NSWorkspace.shared.open(u)   // "System Audio Recording Only" pane
            }
        }
    }

    @objc private func openSettings() {
        if settingsWC == nil { settingsWC = SettingsWindowController(onSave: { [weak self] in self?.restartEngine() }) }
        settingsWC?.showWindow(nil)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func restartEngine() {
        refresh("Applying settings…")
        setupModelDownload()   // a newly-selected model starts downloading (if not already present)
        let old = engine; engine = nil; paused = false
        schedulePaused = false; scheduleOverrideUntil = nil   // a settings save re-baselines the schedule
        let pending = stopTask   // settings saved while paused → that stop may still be in flight; kept set
        let starting = startTask // until done so an interleaved resume can't slip past it (see togglePause)
        Task {
            if let starting { _ = await starting.value }
            if let pending { _ = await pending.value }
            if let old = old { await old.stop() }
            await MainActor.run {
                if self.stopTask == pending { self.stopTask = nil }
                self.startEngineRespectingSchedule()   // a just-edited schedule applies NOW, without
            }                                          // the start-then-stop race of a blind start
        }
    }

    /// Clicking the app icon in /Applications/Launchpad/Dock while it's running → open the tray menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openMenu(); return true
    }

    /// Open the tray menu programmatically (when the app is clicked in /Applications).
    @objc private func openMenu() {
        NSApp.activate(ignoringOtherApps: true)
        statusItem.button?.performClick(nil)
    }

    @objc private func openTranscripts() {
        let dir = EngineConfig.load().transcriptsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// Manual check (menu): ALWAYS gives visible in-app feedback — an alert for up-to-date / newer /
    /// failure — not only a notification (which the user may have silenced, so the menu looked dead).
    @objc private func checkForUpdates() {
        guard !checkingForUpdates else { return }   // one modal at a time — a re-click must not stack alerts
        checkingForUpdates = true
        UpdateChecker.fetchLatest { [weak self] tag, url in   // fetchLatest already calls back on the main queue
            guard let self else { return }
            self.checkingForUpdates = false
            guard let tag else {
                self.showUpdateAlert(title: "Update check failed",
                                     text: "Couldn't reach GitHub. Check your connection and try again.", style: .warning)
                return
            }
            if isNewerVersion(tag, than: macrecVersion) {
                let openURL = updateAlertOpenURL(installedViaBrew: UpdateChecker.installedViaBrew,
                                                 htmlURL: url, releasesURL: UpdateChecker.releasesURL)
                self.showUpdateAlert(title: "macrec \(tag) is available",
                                     text: UpdateChecker.installedViaBrew ? "Run `brew upgrade --cask macrec` to update."
                                                                          : "Open the release page to download it.",
                                     openURL: openURL)
            } else {
                self.showUpdateAlert(title: "You're up to date",
                                     text: "macrec v\(macrecVersion) is the latest release.")
            }
        }
    }

    /// A visible, focus-stealing result for a user-initiated update check. macrec is `.accessory`, so
    /// activate first or the alert can open behind everything (the "no reaction" the user saw). With an
    /// `openURL` it offers Open (default/Return) + Cancel (Esc); otherwise a lone OK.
    private func showUpdateAlert(title: String, text: String, openURL: URL? = nil, style: NSAlert.Style = .informational) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.alertStyle = style
        if openURL != nil {
            a.addButton(withTitle: "Open")                              // first button = default, bound to Return
            a.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"   // Esc dismisses without opening a browser
        }
        let resp = a.runModal()
        if let openURL, resp == .alertFirstButtonReturn { NSWorkspace.shared.open(openURL) }
    }

    /// Background daily check — rides the 30 s tick with a last-run marker (same catch-up-after-
    /// sleep semantics as the daily digest). Silent unless something new is actually out.
    private func maybeCheckForUpdates() {
        guard Pref.bool(Pref.autoUpdateCheck, "MR_AUTO_UPDATE_CHECK", true) else { return }
        let dayF = DateFormatter(); dayF.locale = Locale(identifier: "en_US_POSIX"); dayF.dateFormat = "yyyy-MM-dd"
        let today = dayF.string(from: Date())
        guard Pref.explicit(Pref.updateCheckLastRun, "") != today else { return }
        Pref.d.set(today, forKey: Pref.updateCheckLastRun)
        UpdateChecker.fetchLatest { [weak self] tag, url in
            guard let tag, isNewerVersion(tag, than: macrecVersion) else { return }
            self?.announceUpdate(tag: tag, url: url)
        }
    }

    private func announceUpdate(tag: String, url: String?) {
        // Sanitize the click target through the SAME https-only gate the manual alert uses (nil for
        // brew → no click target) — the notification path must not open a file:/custom-scheme URL either.
        let open = updateAlertOpenURL(installedViaBrew: UpdateChecker.installedViaBrew,
                                      htmlURL: url, releasesURL: UpdateChecker.releasesURL)
        let how = UpdateChecker.installedViaBrew ? "Run: brew upgrade --cask macrec"
                                                 : "Click to open the release page."
        elog("update: \(tag) available (current v\(macrecVersion))")
        Notifier.push(title: "macrec \(tag) is available", body: how, openURL: open)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let credits = NSAttributedString(
            string: "Always-on meeting recorder",
            attributes: [.font: NSFont.systemFont(ofSize: 13), .paragraphStyle: para])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "macrec",
            .applicationVersion: macrecVersion,
            .credits: credits,
        ])
    }

    /// Stop the engine (→ destroys the Core Audio process tap + aggregate device) synchronously, once.
    /// A leaked tap can wedge coreaudiod ("no sound until killall coreaudiod"), so run it on EVERY
    /// termination path: menu Quit, SIGTERM/kickstart, and logout/shutdown (applicationWillTerminate).
    private func stopEngineSync() {
        guard let eng = engine else { return }
        engine = nil   // idempotent — later callers see nil and skip (no double-stop)
        let s = DispatchSemaphore(value: 0)
        Task { await eng.stop(); s.signal() }
        _ = s.wait(timeout: .now() + 15)
    }

    func applicationWillTerminate(_ notification: Notification) { stopEngineSync() }

    @objc private func quit() { stopEngineSync(); NSApp.terminate(nil) }
}

extension AppController: UNUserNotificationCenterDelegate {
    /// Menu-bar agents count as "foreground", which by default swallows banners — show them anyway.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Clicking a "Transcript ready" push opens the saved file.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        // Web links ride under "url" (https-only — sanitized at push time, re-checked here); local
        // transcript paths ride under "file". Keeping them distinct means a URL is never opened as a
        // file path, nor a path as a URL (the old shared "file" key + hasPrefix("http") did both).
        if let s = info["url"] as? String, let u = URL(string: s), u.scheme?.lowercased() == "https" {
            NSWorkspace.shared.open(u)
        } else if let p = info["file"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
        }
        completionHandler()
    }
}

var appController: AppController?   // retained for process lifetime

func runMenuBarApp() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon (LSUIElement)
    let c = AppController()
    appController = c
    app.delegate = c
    app.run()
    exit(0)
}

/// Install a one-shot stop handler for SIGINT/SIGTERM. Returns the source (keep it alive).
func installStopHandler(_ handler: @escaping () -> Void) {
    let q = DispatchQueue(label: "macrec.stop-signal")
    for s in [SIGINT, SIGTERM] {
        signal(s, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: s, queue: q)
        src.setEventHandler(handler: handler)
        src.resume()
        signalSources.append(src)
    }
}

// MARK: - main

/// Single source of truth for the version — a compile-time constant so `macrec version` reports
/// correctly even when run via the Homebrew `bin/macrec` symlink (where Bundle.main resolves to
/// /opt/homebrew/bin, not the .app, so the Info.plist can't be read). install.sh / package.sh
/// stamp CFBundleShortVersionString from THIS value, so the binary and the bundle never drift.
let macrecVersion = "0.5.0"

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
      sweep                  run one retention/archive pass (WAV→AAC tiers) and exit
                             [--audio-dir D] [--transcripts-dir D] [--raw-days N] [--keep-days N]
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

@main
struct Main {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())

        // The test/snapshot subcommands build the real Settings pane and the real overlay, both of which
        // ask every engine whether it is ready — a Keychain read each. Run them against no credentials at
        // all: an unsigned dev build would otherwise raise an authorization prompt per read.
        if let a = args.first, ["selftest", "settings-snapshot", "icon-snapshot", "caption-snapshot"].contains(a) {
            Keychain.disabled = true
        }

        // Subcommands: help / version (accept the common flag spellings too).
        if let a = args.first, ["help", "--help", "-h"].contains(a) { printMacrecHelp(); exit(0) }
        if let a = args.first, ["version", "--version", "-v"].contains(a) { print("macrec \(macrecVersion)"); exit(0) }

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

        // Subcommand: caption-snapshot — render the live overlay at several opacities over a checkerboard.
        // The one thing to LOOK for: the background fades, the captions never do.
        if args.first == "caption-snapshot" {
            let dir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/tmp/macrec-caption-shots")
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            guard #available(macOS 26, *) else { print("caption-snapshot: needs macOS 26"); exit(1) }
            let w = LiveCaptionWindow(onClose: {}, onReconfigure: {}, onRestyle: {})
            let files = w.snapshotOpacities([1.0, 0.6, 0.3], to: dir)
            for f in files { print(f.path) }
            if files.isEmpty {
                print("caption-snapshot: FAILED — screencapture could not read the window. Grant Screen "
                    + "Recording to the terminal you ran this from (System Settings › Privacy & Security "
                    + "› Screen Recording), then run it again. A translucent window cannot be captured "
                    + "offscreen: its material is composited by the window server.")
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
                Task { await engine.stop(); s.signal() }
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
