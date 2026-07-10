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
