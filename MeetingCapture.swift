// meeting-capture — record system audio (excluding self) + microphone, mix to 16kHz mono WAV.
//
// Usage:
//   meeting-capture --out <path.wav> [--no-mic] [--duration <seconds>]
//   meeting-capture mic-status        # prints "1" if the default input device is in use, else "0"
//
// Stops on SIGINT/SIGTERM (or after --duration), mixes the two sources, prints the final
// WAV path to stdout. All diagnostics go to stderr.
//
// Requires (macOS 15+): Screen Recording permission (system audio via ScreenCaptureKit) and
// Microphone permission. Built for macOS 26.

import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreAudio
import CoreGraphics
import AppKit
import EventKit
import ServiceManagement

// MARK: - helpers

func elog(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

// MARK: - permissions (preflighting these prevents startCapture() from hanging under launchd)

func hasScreenPermission() -> Bool { CGPreflightScreenCaptureAccess() }

func micAuthorized() -> Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

/// Triggers the Screen Recording + Microphone prompts and registers this binary in the TCC
/// lists (so it can be enabled in System Settings even when no prompt can be shown). Never hangs.
func requestPermissions() -> (screen: Bool, mic: Bool) {
    let screen = CGRequestScreenCaptureAccess()
    let sem = DispatchSemaphore(value: 0)
    var mic = micAuthorized()
    if !mic {
        AVCaptureDevice.requestAccess(for: .audio) { granted in mic = granted; sem.signal() }
        _ = sem.wait(timeout: .now() + 3)  // don't block forever if no prompt can show
    }
    return (screen, mic)
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

// MARK: - per-source writer (converts to canon, writes a temp float32 WAV)

final class SourceWriter {
    let url: URL
    private let file: AVAudioFile
    private var converter: AVAudioConverter?
    private var srcFormat: AVAudioFormat?
    var buffersIn = 0
    var framesIn: AVAudioFramePosition = 0
    var framesOut: AVAudioFramePosition = 0
    var convErrors = 0
    var peak: Float = 0   // max abs sample seen — ~0 means this source recorded silence
    var recentLevel: Float = 0   // peak of the most recent buffer — for the live menu meter
    var voicedFrames: AVAudioFramePosition = 0   // # samples above the voice threshold
    static let voiceThreshold: Float = 0.02      // ~-34 dBFS — speech-ish floor

    /// Seconds of "voiced" (above-threshold) audio — used to decide if a segment is worth transcribing.
    var voicedSeconds: Double { Double(voicedFrames) / canon.sampleRate }

    var stats: String {
        let secs = Double(framesOut) / canon.sampleRate
        return String(format: "%@: %.1fs peak=%.4f voiced=%.1fs buffersIn=%d convErrors=%d srcRate=%.0f",
                      url.lastPathComponent, secs, peak, voicedSeconds, buffersIn, convErrors, srcFormat?.sampleRate ?? 0)
    }

    init(url: URL) throws {
        self.url = url
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        self.file = try AVAudioFile(forWriting: url, settings: settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let inBuf = SourceWriter.pcm(from: sampleBuffer) else { return }
        buffersIn += 1
        framesIn += AVAudioFramePosition(inBuf.frameLength)
        if converter == nil || srcFormat != inBuf.format {
            srcFormat = inBuf.format
            converter = AVAudioConverter(from: inBuf.format, to: canon)
        }
        guard let conv = converter else { return }
        let ratio = canon.sampleRate / inBuf.format.sampleRate
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: canon, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        if let err = err { convErrors += 1; if convErrors <= 3 { elog("convert error: \(err)") }; return }
        guard outBuf.frameLength > 0 else { return }
        if let p = outBuf.floatChannelData?[0] {
            var bufMax: Float = 0
            for i in 0..<Int(outBuf.frameLength) {
                let a = abs(p[i])
                if a > bufMax { bufMax = a }
                if a > SourceWriter.voiceThreshold { voicedFrames += 1 }
            }
            if bufMax > peak { peak = bufMax }
            recentLevel = bufMax   // live meter
        }
        do { try file.write(from: outBuf); framesOut += AVAudioFramePosition(outBuf.frameLength) }
        catch { elog("write error: \(error)") }
    }

    /// Copy a CMSampleBuffer's PCM data into an AVAudioPCMBuffer in the buffer's own format.
    static func pcm(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        var asbd = asbdPtr.pointee
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let n = CMSampleBufferGetNumSamples(sb)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList)
        return st == noErr ? buf : nil
    }
}

// MARK: - mixdown (sum two float32 WAVs to one 16-bit mono WAV)

func mixDown(sysURL: URL, micURL: URL?, outURL: URL) throws {
    let sysFile = try AVAudioFile(forReading: sysURL)
    let micFile = try micURL.map { try AVAudioFile(forReading: $0) }

    let outSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let outFile = try AVAudioFile(forWriting: outURL, settings: outSettings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)

    let block: AVAudioFrameCount = 16000  // ~1s chunks

    // Drive the loop by file position, NOT by short reads — AVAudioFile.read() may legitimately
    // return fewer frames than requested before EOF; treating that as EOF truncates the mix.
    func remaining(_ f: AVAudioFile) -> Bool { f.framePosition < f.length }

    while remaining(sysFile) || (micFile.map(remaining) ?? false) {
        guard let out = AVAudioPCMBuffer(pcmFormat: canon, frameCapacity: block) else { break }

        let sb = AVAudioPCMBuffer(pcmFormat: canon, frameCapacity: block)!
        if remaining(sysFile) { try sysFile.read(into: sb, frameCount: block) }

        var mb: AVAudioPCMBuffer?
        if let micFile = micFile, remaining(micFile) {
            let b = AVAudioPCMBuffer(pcmFormat: canon, frameCapacity: block)!
            try micFile.read(into: b, frameCount: block)
            mb = b
        }

        let sn = Int(sb.frameLength)
        let mn = Int(mb?.frameLength ?? 0)
        let n = max(sn, mn)
        if n == 0 { break }

        out.frameLength = AVAudioFrameCount(n)
        let op = out.floatChannelData![0]
        let sp = sb.floatChannelData![0]
        let mp = mb?.floatChannelData?[0]
        for i in 0..<n {
            var v: Float = 0
            if i < sn { v += sp[i] }
            if let mp = mp, i < mn { v += mp[i] }
            if v > 1 { v = 1 } else if v < -1 { v = -1 }
            op[i] = v
        }
        try outFile.write(from: out)
    }
}

// MARK: - recorder (ScreenCaptureKit)

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    var sysWriter: SourceWriter?
    var micWriter: SourceWriter?
    let queue = DispatchQueue(label: "meeting-capture.audio")
    var stream: SCStream?

    init(sysWriter: SourceWriter?, micWriter: SourceWriter?) {
        self.sysWriter = sysWriter
        self.micWriter = micWriter
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sb) else { return }
        switch type {
        case .audio: sysWriter?.append(sb)
        case .microphone: micWriter?.append(sb)  // (unused now — mic comes via appendMic)
        default: break  // .screen frames are ignored
        }
    }

    /// Mic samples arrive from a SEPARATE AVCaptureSession (not ScreenCaptureKit). Capturing
    /// system audio + mic *both* through SCK makes macOS build an aggregate device that hijacks
    /// the default output (silences the user). Routing mic through its own path avoids that.
    /// Appended on `queue` so it shares synchronization with sys writes and rotation swaps.
    func appendMic(_ sb: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sb) else { return }
        queue.async { self.micWriter?.append(sb) }
    }

    var onStopped: (() -> Void)?
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        elog("stream stopped with error: \(error)")
        onStopped?()   // display slept / stream died → let the engine rebuild it
    }

    /// Drain in-flight callbacks, then release the AVAudioFiles so they flush their WAV headers
    /// to disk before mixdown reads them.
    func finalizeWriters() {
        queue.sync { }
        if let s = sysWriter {
            elog("stats sys " + s.stats)
            if s.framesOut > 16000 && s.peak < 0.001 {
                elog("⚠ system audio was SILENT (peak≈0) — other participants won't be transcribed. Check: (1) meeting-capture has 'Screen & System Audio Recording' permission, (2) audio output routing (USB DAC / SoundSource).")
            }
        }
        if let m = micWriter { elog("stats mic " + m.stats) }
        sysWriter = nil
        micWriter = nil
    }
}

// MARK: - default-output guard
//
// Starting an AVCaptureSession with an audio input (and, on some macOS versions, (re)building the
// ScreenCaptureKit audio stream) resets the system's DEFAULT OUTPUT device to the built-in speakers
// as a side effect — so you suddenly "can't hear" your meeting. OutputKeeper (below) remembers the
// user's preferred output while it's known-good and re-pins it for a window after each capture
// transition, so the chosen device sticks across sleep/wake and restarts.

func defaultOutputDeviceID() -> AudioDeviceID {
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return id
}

func setDefaultOutputDeviceID(_ id: AudioDeviceID) {
    guard id != 0 else { return }
    var dev = id
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                               UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
}

/// Device UID — stable across reboots/replug (unlike the volatile AudioDeviceID).
func outputDeviceUID(_ id: AudioDeviceID) -> String? {
    guard id != 0 else { return nil }
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var cf = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr else { return nil }
    let s = cf as String
    return s.isEmpty ? nil : s
}

/// Find an output-capable device by its UID.
func outputDevice(forUID uid: String) -> AudioDeviceID? {
    var size = UInt32(0)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids.first { outputDeviceUID($0) == uid }
}

/// Keeps the user's preferred OUTPUT device pinned across capture (re)starts and sleep/wake.
///
/// macOS resets the default output to the built-in speakers around sleep/wake (and capture restart),
/// so audio stops coming out of the chosen device. A "snapshot at restart" is too late — by then the
/// output is already reset. Instead we REMEMBER the preferred device while it's known-good (before
/// sleep, and during steady-state use) and ENFORCE it for a window after each capture transition via
/// a CoreAudio listener — while still honoring a deliberate user switch made during normal use.
final class OutputKeeper {
    static let shared = OutputKeeper()
    private let key = "preferredOutputUID"
    private var enforceUntil = Date.distantPast
    private var listening = false

    private var preferredUID: String? {
        get { Pref.d.string(forKey: key) }
        set { if let v = newValue { Pref.d.set(v, forKey: key) } }
    }

    /// Record the current output as preferred — call when it's known-good (engine start w/o a stored
    /// preference, before sleep, and on deliberate steady-state changes).
    func rememberCurrentAsPreferred() {
        if let u = outputDeviceUID(defaultOutputDeviceID()) {
            if preferredUID != u { elog("audio: preferred output = \(u)") }
            preferredUID = u
        }
    }

    /// A capture (re)start / wake happened — enforce the preferred device for ~30s (the reset can land
    /// several seconds late) and make sure the change listener is installed.
    func onCaptureStarted() {
        if preferredUID == nil { rememberCurrentAsPreferred() }   // bootstrap on first run
        enforceUntil = Date().addingTimeInterval(30)
        startListening()
        let fix: () -> Void = { [weak self] in self?.enforce() }
        fix()
        for d in [0.3, 1, 2, 4, 8, 15] { DispatchQueue.global().asyncAfter(deadline: .now() + d, execute: fix) }
    }

    private func enforce() {
        guard Date() < enforceUntil, let want = preferredUID else { return }
        if outputDeviceUID(defaultOutputDeviceID()) != want, let dev = outputDevice(forUID: want) {
            elog("audio: output hijacked → restoring preferred \(want)")
            setDefaultOutputDeviceID(dev)
        }
    }

    private func startListening() {
        guard !listening else { return }
        listening = true
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.global()) { [weak self] _, _ in
            guard let self = self else { return }
            if Date() < self.enforceUntil { self.enforce() }          // within a transition → undo hijack
            else { self.rememberCurrentAsPreferred() }                // steady state → adopt user's choice
        }
    }
}

// MARK: - microphone capture (separate AVCaptureSession — does NOT touch the output device)

final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let q = DispatchQueue(label: "meeting-capture.mic")
    private weak var recorder: Recorder?

    func start(into rec: Recorder) throws {
        recorder = rec
        if session.inputs.isEmpty {   // configure once; idempotent so suspend→resume just toggles running
            guard let dev = AVCaptureDevice.default(for: .audio) else {
                throw NSError(domain: "meeting-capture", code: 4, userInfo: [NSLocalizedDescriptionKey: "no default audio input device"])
            }
            let input = try AVCaptureDeviceInput(device: dev)
            session.beginConfiguration()
            if session.canAddInput(input) { session.addInput(input) }
            output.setSampleBufferDelegate(self, queue: q)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
        }
        if !session.isRunning { session.startRunning() }
    }

    func stop() { if session.isRunning { session.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        recorder?.appendMic(sampleBuffer)
    }
}

// MARK: - preferences (UserDefaults > env var > built-in default)
//
// 설정 UI는 UserDefaults에 쓴다. 헤드리스 `engine` CLI/파워유저는 MR_* env로 override 가능.
// 우선순위: UserDefaults(키가 있으면) > env > 기본값.

enum Pref {
    // 전용 suite (bundle id와 '다른' 이름이어야 함 — suiteName==bundleID면 nil 반환).
    // launchd가 .app 내부 바이너리를 직접 exec할 때 .standard 도메인이 안 잡히는 문제를 우회.
    // CLI에서 보려면: `defaults read com.ikhoon.MeetingRecorder`
    static let suiteName = "com.ikhoon.MeetingRecorder"
    static let d = UserDefaults(suiteName: suiteName) ?? .standard
    // 키 상수 (설정 UI와 공유)
    static let segment = "segmentSeconds", voiceMin = "voiceMinSeconds", lang = "whisperLang"
    static let keepAudio = "keepAudio", audioRetention = "audioRetentionDays", txtRetention = "transcriptRetentionDays"
    static let exclude = "excludeApps", txtDir = "transcriptsDir", vad = "vadEnabled", autoStart = "autoStart"
    static let cal = "useCalendarTitles", model = "whisperModelName"
    static let autostartOffered = "autostartOffered"   // one-shot: auto-enabled the login item once
    static let systemAudio = "captureSystemAudio"       // capture other-party (system) audio via SCK
    static let audioDir = "audioDir"                    // separate root for kept .wav (default OUTPUT_ROOT/audio)

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
    /// The .app bundle URL when running as Contents/MacOS/meeting-capture; nil for a loose CLI binary.
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
    let bytes: Int64        // verified size; download threshold = bytes/2 (rejects partials / HTML error pages)
    var url: String { "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)" }
    var minBytes: Int64 { bytes / 2 }
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
    /// Currently selected model (UserDefaults > env > default).
    static var selected: WhisperModelSpec { spec(Pref.str(Pref.model, "MR_WHISPER_MODEL", defaultName)) }
}

/// Downloads the selected transcription model on first run / on change (too big to bundle).
/// Stored under ~/Library/Application Support/MeetingRecorder/models/, keyed by filename so
/// multiple models coexist and switching back never re-downloads.
final class ModelStore: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelStore()

    /// Download progress: 0...1 while running, 1.0 done, <0 failed. Delivered on the main queue.
    var onProgress: ((Double) -> Void)?
    private var session: URLSession?
    private var downloadingName: String?      // name of the model currently downloading (nil = idle)

    var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingRecorder/models", isDirectory: true)
    }
    func path(for s: WhisperModelSpec) -> URL { dir.appendingPathComponent(s.filename) }
    func isReady(_ s: WhisperModelSpec) -> Bool { fileBytes(path(for: s)) >= s.minBytes }

    /// The currently-selected model.
    var spec: WhisperModelSpec { WhisperCatalog.selected }
    var isReady: Bool { isReady(spec) }

    /// Path EngineConfig should use for the current selection: App Support if present, else a dev
    /// ~/whisper-models copy, else the (not-yet-filled) App Support path so the download lands there.
    var resolvedModelPath: String {
        let s = spec
        if isReady(s) { return path(for: s).path }
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
        if isReady(s) || fileBytes(devPath(s)) >= s.minBytes {   // already available locally
            if downloadingName != nil { cancelDownload() }
            return
        }
        if downloadingName == s.name { return }                   // already fetching this one
        if downloadingName != nil { cancelDownload() }            // switch download target

        downloadingName = s.name
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urlStr = ProcessInfo.processInfo.environment["MR_MODEL_URL"] ?? s.url
        guard let url = URL(string: urlStr) else { downloadingName = nil; return }
        let sess = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = sess
        elog("model: downloading \(s.name) \(urlStr) → \(path(for: s).path)")
        sess.downloadTask(with: url).resume()
    }

    private func cancelDownload() {
        session?.invalidateAndCancel(); session = nil; downloadingName = nil
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
        guard s === session, t > 0 else { return }
        let p = Double(w) / Double(t)
        DispatchQueue.main.async { self.onProgress?(p) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo loc: URL) {
        guard s === session, let name = downloadingName else { return }
        let sp = WhisperCatalog.spec(name)
        let size = fileBytes(loc)                       // temp file is deleted after we return — move now
        guard size >= sp.minBytes else {
            elog("model: \(name) downloaded too small (\(size) bytes) — discarding"); finish(ok: false); return
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
        downloadingName = nil
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
    var keepAudio: Bool                 // false면 전사만 남기고 오디오 삭제
    var audioRetentionDays: Int         // 0 = 무제한
    var transcriptRetentionDays: Int    // 0 = 무제한
    var excludeBundleIds: [String]

    static func load() -> EngineConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tdir = URL(fileURLWithPath: Pref.str(Pref.txtDir, "MR_TRANSCRIPTS_DIR",
                                                 home.appendingPathComponent("src/LINE/work/transcripts").path))
        let excl = Pref.str(Pref.exclude, "MR_EXCLUDE_APPS", "com.spotify.client")
            .split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        return EngineConfig(
            segmentSeconds: Pref.dbl(Pref.segment, "MR_SEGMENT_SECONDS", 3600),
            voiceMinSeconds: Pref.dbl(Pref.voiceMin, "MR_VOICE_MIN_SECONDS", 5),
            transcriptsDir: tdir,
            // Audio lives in its OWN root (separate from transcripts) — default OUTPUT_ROOT/audio
            // (sibling of transcripts), overridable via Settings / MR_AUDIO_DIR.
            audioDir: URL(fileURLWithPath: Pref.str(Pref.audioDir, "MR_AUDIO_DIR",
                                                    tdir.deletingLastPathComponent().appendingPathComponent("audio").path)),
            workDir: URL(fileURLWithPath: Pref.str("workDir", "MR_WORK_DIR", "/tmp/meeting-recorder-segments")),
            // Defaults prefer what's bundled in the .app (self-contained); env/UserDefaults still override.
            whisperCli: Pref.str("whisperCli", "MR_WHISPER_CLI", BundledTools.whisperCli ?? "/opt/homebrew/bin/whisper-cli"),
            whisperModel: Pref.str("whisperModel", "MR_WHISPER_GGML", ModelStore.shared.resolvedModelPath),
            vadModel: Pref.str("vadModel", "MR_VAD_MODEL",
                               BundledTools.vadModel ?? home.appendingPathComponent("whisper-models/ggml-silero-v5.1.2.bin").path),
            vadEnabled: Pref.bool(Pref.vad, "MR_VAD", true),
            useCalendarTitles: Pref.bool(Pref.cal, "MR_CALENDAR_TITLES", true),
            whisperLang: Pref.str(Pref.lang, "MR_WHISPER_LANG", "auto"),
            keepAudio: Pref.bool(Pref.keepAudio, "MR_KEEP_AUDIO", true),
            audioRetentionDays: Pref.int(Pref.audioRetention, "MR_AUDIO_RETENTION_DAYS", 30),
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
    let sysPeak: Float
    let micPeak: Float
    let durationSeconds: Double
    /// Either side speaking is worth transcribing (covers listen-only meetings where only sys speaks).
    var voicedSeconds: Double { max(micVoicedSeconds, sysVoicedSeconds) }
}

func segFormatter() -> DateFormatter {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd-HHmmss"; return f
}

/// One always-on SCStream whose per-source writers are swapped on a timer (hourly rotation),
/// so capture never stops and there are no gaps between segments.
final class CaptureSession {
    private var stream: SCStream?
    private let mic = MicCapture()
    let rec = Recorder(sysWriter: nil, micWriter: nil)
    private let excludeBundleIds: [String]
    private let workDir: URL
    private var segStart = Date()

    var onStreamStopped: (() -> Void)?   // engine sets this to trigger recovery

    init(excludeBundleIds: [String], workDir: URL) {
        self.excludeBundleIds = excludeBundleIds
        self.workDir = workDir
        rec.onStopped = { [weak self] in self?.onStreamStopped?() }
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
        try await buildStream()
        try mic.start(into: rec)   // separate mic path (AVCaptureSession) — does not touch output
    }

    /// Build & start the system-audio SCStream, re-acquiring the current display. Used by start()
    /// and by restartStream() to recover after the display slept and killed the stream (-3815).
    /// NB: no captureMicrophone / no forced sampleRate — capturing system audio AND mic through SCK
    /// (or forcing a device format) makes macOS build an aggregate device and hijack the output.
    private func buildStream() async throws {
        // Mic-only fallback: skip system-audio (SCK) capture entirely so nothing competes with
        // SoundSource / other audio tools for the system audio path.
        guard Pref.bool(Pref.systemAudio, "MR_SYSTEM_AUDIO", true) else {
            elog("engine: system-audio capture OFF (mic-only) — coexists with SoundSource etc.")
            return
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "meeting-capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display for SCContentFilter"])
        }
        let excluded = content.applications.filter { excludeBundleIds.contains($0.bundleIdentifier) }
        if !excluded.isEmpty { elog("engine: excluding audio from \(excluded.map { $0.bundleIdentifier }.joined(separator: ", "))") }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 4)
        let s = SCStream(filter: filter, configuration: config, delegate: rec)
        rec.stream = s
        try s.addStreamOutput(rec, type: .screen, sampleHandlerQueue: rec.queue)
        try s.addStreamOutput(rec, type: .audio, sampleHandlerQueue: rec.queue)
        try await s.startCapture()
        stream = s
    }

    /// Rebuild the system-audio stream after it died (display sleep). Keeps the current writers + mic
    /// running, so the in-progress segment just resumes capturing system audio. Returns success.
    func restartStream() async -> Bool {
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        do { try await buildStream(); try mic.start(into: rec); return true }   // resume mic too
        catch { return false }
    }

    /// Pause capture (mic + system audio) on lock/sleep — release the audio + display cleanly.
    func suspendStream() async {
        mic.stop()
        if let s = stream { try? await s.stopCapture() }
        stream = nil
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
        if let s = stream { try? await s.stopCapture() }
        stream = nil
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

    struct Match { let title: String; let link: String?; let attendees: [String] }

    /// Best event overlapping [start, end] — prefers one with a Zoom/Meet/Teams link.
    static func match(start: Date, end: Date) -> Match? {
        guard authorized else { return nil }
        let pred = store.predicateForEvents(withStart: start.addingTimeInterval(-300), end: end.addingTimeInterval(60), calendars: nil)
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
        func overlap(_ e: EKEvent) -> TimeInterval { max(0, min(e.endDate, end).timeIntervalSince(max(e.startDate, start))) }

        let chosen = events.sorted { a, b in
            let la = link(a) != nil, lb = link(b) != nil
            if la != lb { return la }                 // events with a meeting link win
            return overlap(a) > overlap(b)            // else the one overlapping most
        }.first!
        let names = (chosen.attendees ?? []).compactMap { $0.name }.filter { !$0.isEmpty }
        return Match(title: chosen.title, link: link(chosen), attendees: names)
    }
}

// MARK: - transcriber (per-track whisper-cli → speaker-labeled, time-merged transcript)

enum Transcriber {
    /// Run whisper-cli (VAD + suppress-non-speech) on a 16kHz/16-bit WAV; return its timestamped stdout.
    private static func runWhisper(_ wav16: URL, _ cfg: EngineConfig) -> String {
        guard FileManager.default.isExecutableFile(atPath: cfg.whisperCli),
              FileManager.default.fileExists(atPath: cfg.whisperModel) else {
            elog("transcribe: whisper-cli or model missing (\(cfg.whisperCli))"); return ""
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cfg.whisperCli)
        var args = ["-m", cfg.whisperModel, "-f", wav16.path, "-l", cfg.whisperLang, "-np", "-sns"]
        if cfg.vadEnabled && FileManager.default.fileExists(atPath: cfg.vadModel) {
            args += ["--vad", "--vad-model", cfg.vadModel]
        }
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

    /// Transcribe mic ("나") and system ("상대") SEPARATELY, then merge by time into a speaker-labeled
    /// transcript. Mixes a kept WAV only when keepAudio. Returns (mixedWav?, text).
    static func transcribe(_ seg: CompletedSegment, cfg: EngineConfig) -> (mixed: URL?, text: String)? {
        var mixed: URL? = nil
        if cfg.keepAudio {
            let stem = URL(fileURLWithPath: seg.sysURL.path).deletingPathExtension().deletingPathExtension()
            let m = URL(fileURLWithPath: stem.path + ".wav")
            do { try mixDown(sysURL: seg.sysURL, micURL: seg.micURL, outURL: m); mixed = m }
            catch { elog("mixdown: \(error)") }
        }
        var merged: [(start: Double, who: String, text: String)] = []
        if let mic16 = convert16(seg.micURL) {
            merged += parse(runWhisper(mic16, cfg)).map { (start: $0.0, who: "나", text: $0.1) }
            try? FileManager.default.removeItem(at: mic16)
        }
        if let sys16 = convert16(seg.sysURL) {
            merged += parse(runWhisper(sys16, cfg)).map { (start: $0.0, who: "상대", text: $0.1) }
            try? FileManager.default.removeItem(at: sys16)
        }
        merged.sort { $0.start < $1.start }
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
    private let timerQueue = DispatchQueue(label: "meeting-recorder.timer")
    private let processQueue = DispatchQueue(label: "meeting-recorder.process")  // serial: transcribe one at a time
    private var timer: DispatchSourceTimer?
    private(set) var running = false
    private var recovering = false
    private var suspended = false   // true while the display/system is asleep
    var onTranscriptSaved: ((String) -> Void)?   // (메시지) — UI 상태 갱신용
    var onSegmentResult: ((String) -> Void)?      // (메시지) — 발화 없어 버려도 알림

    init(cfg: EngineConfig) {
        self.cfg = cfg
        self.session = CaptureSession(excludeBundleIds: cfg.excludeBundleIds, workDir: cfg.workDir)
    }

    /// 정시 회전을 기다리지 않고 지금까지 녹음분을 즉시 잘라 전사·저장한다 (트레이 "지금 전사").
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
        return (session.rec.micWriter?.recentLevel ?? 0, session.rec.sysWriter?.recentLevel ?? 0)
    }

    /// Rebuild the capture stream after the display slept (it kills the SCStream with -3815).
    /// Retries every 2s until the display is back. Mic keeps running; only system audio is rebuilt.
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
        guard hasScreenPermission(), micAuthorized() else {
            elog("engine: Screen Recording / Microphone permission not granted — requesting.")
            _ = requestPermissions()
            throw NSError(domain: "meeting-capture", code: 3, userInfo: [NSLocalizedDescriptionKey: "permissions not granted"])
        }
        session.onStreamStopped = { [weak self] in self?.recover() }
        try await session.start()
        running = true
        elog("engine: recording (segment=\(Int(cfg.segmentSeconds))s, voiceMin=\(Int(cfg.voiceMinSeconds))s, exclude=\(cfg.excludeBundleIds.joined(separator: ",")))")
        processQueue.async { [weak self] in self?.cleanupRetention() }   // tidy old files on start
        // Sleep/wake: stop capture cleanly on sleep (don't fight the display powering down) and
        // resume on wake — avoids hammering ScreenCaptureKit while the display is off.
        let wc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.suspendForSleep() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.wake() }
        }
        // Screen lock/unlock (distributed notifications) — pause while locked, too.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.suspendForSleep() }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.wake() }
        // 정시 정렬: 첫 회전을 시계 경계(정시, 또는 세그먼트 크기 배수)에 맞춘다.
        // 예: segment=3600이면 다음 :00, 900이면 다음 :00/:15/:30/:45.
        let cal = Calendar.current; let nowD = Date()
        let intoHour = Double(cal.component(.minute, from: nowD) * 60 + cal.component(.second, from: nowD))
        let firstDelay = cfg.segmentSeconds - intoHour.truncatingRemainder(dividingBy: cfg.segmentSeconds)
        elog("engine: first rotation in \(Int(firstDelay))s (정시 정렬), then every \(Int(cfg.segmentSeconds))s")
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

    /// Delete audio/transcripts older than the retention window (0 = keep forever).
    private func cleanupRetention() {
        let fm = FileManager.default
        // Recurse under each root so retention prunes the monthly subfolders too:
        // transcripts/YYYY-MM/*.md and audioDir/YYYY-MM/*.wav (plus any legacy layout).
        func purge(_ root: URL, days: Int, ext: String) {
            guard days > 0,
                  let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            var n = 0
            for case let u as URL in en where u.pathExtension.lowercased() == ext {
                if let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, m < cutoff {
                    try? fm.removeItem(at: u); n += 1
                }
            }
            if n > 0 { elog("engine: retention — \(ext) \(n)개 삭제(>\(days)일)") }
        }
        purge(cfg.audioDir, days: cfg.audioRetentionDays, ext: "wav")
        purge(cfg.transcriptsDir, days: cfg.transcriptRetentionDays, ext: "md")
    }

    private func process(_ seg: CompletedSegment) {
        elog("engine: segment \(segFormatter().string(from: seg.start)) — voiced mic=\(String(format: "%.1f", seg.micVoicedSeconds))s sys=\(String(format: "%.1f", seg.sysVoicedSeconds))s (micPeak=\(String(format: "%.3f", seg.micPeak)) sysPeak=\(String(format: "%.3f", seg.sysPeak))) dur=\(Int(seg.durationSeconds))s")
        defer { try? FileManager.default.removeItem(at: seg.sysURL); try? FileManager.default.removeItem(at: seg.micURL) }

        // 내 마이크든 상대(시스템)든 누군가 말했으면 전사한다 (듣기만 한 미팅 포함).
        guard seg.voicedSeconds >= cfg.voiceMinSeconds else {
            elog("engine:   → no speech (\(String(format: "%.1f", seg.voicedSeconds))s < \(Int(cfg.voiceMinSeconds))s), discarding")
            onSegmentResult?("No speech — skipped")
            return
        }
        // Model not downloaded yet (first run) — defer rather than write a "전사 실패" file.
        guard FileManager.default.fileExists(atPath: cfg.whisperModel) else {
            elog("engine:   → model not ready (\(cfg.whisperModel)) — deferring transcription")
            onSegmentResult?("Downloading model — transcription deferred")
            return
        }
        onSegmentResult?("Transcribing…")
        guard let (mixed, text) = Transcriber.transcribe(seg, cfg: cfg) else { return }
        do {
            let url = try writeTranscript(seg: seg, text: text, mixed: mixed)
            onTranscriptSaved?("Saved: \(url.lastPathComponent)")
        } catch { elog("engine: writeTranscript: \(error)") }
    }

    @discardableResult
    private func writeTranscript(seg: CompletedSegment, text: String, mixed: URL?) throws -> URL {
        let fm = FileManager.default
        let nameF = DateFormatter(); nameF.locale = Locale(identifier: "en_US_POSIX"); nameF.dateFormat = "yyyy-MM-dd-HHmm"
        let dayF = DateFormatter(); dayF.locale = Locale(identifier: "en_US_POSIX"); dayF.dateFormat = "yyyy-MM-dd"
        let hmF = DateFormatter(); hmF.locale = Locale(identifier: "en_US_POSIX"); hmF.dateFormat = "HH:mm"
        let monthF = DateFormatter(); monthF.locale = Locale(identifier: "en_US_POSIX"); monthF.dateFormat = "yyyy-MM"

        // Organize transcripts into monthly subfolders: transcripts/YYYY-MM/…  (audio under YYYY-MM/audio/).
        let monthDir = cfg.transcriptsDir.appendingPathComponent(monthF.string(from: seg.start), isDirectory: true)
        try fm.createDirectory(at: monthDir, withIntermediateDirectories: true)
        let end = seg.start.addingTimeInterval(seg.durationSeconds)
        let mins = Int((seg.durationSeconds + 30) / 60)

        // Title the transcript from the overlapping calendar event (prefers ones with a meeting link).
        let event = cfg.useCalendarTitles ? CalendarLookup.match(start: seg.start, end: end) : nil
        let title = event?.title ?? "자동 전사"
        let base = nameF.string(from: seg.start)
        let slug = event.map { "\(base)-\(slugify($0.title))" } ?? base

        // keep the mixed WAV per the keepAudio setting (mixed is nil when keepAudio is off)
        var audioLine = "- 오디오: _(보관 안 함)_"
        if cfg.keepAudio, let mixed = mixed {
            let audioMonthDir = cfg.audioDir.appendingPathComponent(monthF.string(from: seg.start), isDirectory: true)
            try fm.createDirectory(at: audioMonthDir, withIntermediateDirectories: true)
            let keptAudio = audioMonthDir.appendingPathComponent("\(slug).wav")
            try? fm.removeItem(at: keptAudio)
            try fm.moveItem(at: mixed, to: keptAudio)
            audioLine = "- 오디오: [\(slug).wav](\(relativePath(fromDir: monthDir, toFile: keptAudio)))"
        }

        var meta = ""
        if let link = event?.link { meta += "\n- 회의 링크: \(link)" }
        if let names = event?.attendees, !names.isEmpty { meta += "\n- 참석자: \(names.prefix(12).joined(separator: ", "))" }

        let body = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "_(전사 실패 — whisper-cli/모델 확인: \(cfg.whisperModel))_" : text
        let md = """
        # \(dayF.string(from: seg.start)) \(hmF.string(from: seg.start))–\(hmF.string(from: end)) — \(title)

        > [연속 녹음] whisper-cli 자동 전사 (화자: 나=마이크, 상대=시스템). \(cfg.excludeBundleIds.joined(separator: ", ")) 제외.

        - 시각: \(dayF.string(from: seg.start)) \(hmF.string(from: seg.start))–\(hmF.string(from: end)) (\(mins)분)
        - 발화: mic \(String(format: "%.1f", seg.micVoicedSeconds))s · sys \(String(format: "%.1f", seg.sysVoicedSeconds))s · 모델: `\(URL(fileURLWithPath: cfg.whisperModel).lastPathComponent)`
        \(audioLine)\(meta)
        - 태그: #transcript #auto

        ## 전사 (transcript)

        \(body)

        ---
        _자동 생성. 재사용할 지식은 `topics/`로 정제하세요._
        """
        let mdURL = monthDir.appendingPathComponent("\(slug).md")
        try md.write(to: mdURL, atomically: true, encoding: .utf8)
        elog("engine:   → 전사 저장: \(mdURL.path)")
        return mdURL
    }
}

// MARK: - settings window (NSGridView form, persists to UserDefaults)

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let onSave: () -> Void
    private let segPopup = NSPopUpButton(), langPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let audioRetPopup = NSPopUpButton(), txtRetPopup = NSPopUpButton()
    private let addAppPopup = NSPopUpButton()
    private let voiceField = NSTextField(), dirField = NSTextField(), audioDirField = NSTextField()
    private let excludeTokens = NSTokenField()   // multiple bundle ids as tokens
    private let keepAudioBtn = NSButton(checkboxWithTitle: "Keep audio (WAV) too", target: nil, action: nil)
    private let vadBtn = NSButton(checkboxWithTitle: "Remove noise/silence (VAD)", target: nil, action: nil)
    private let calBtn = NSButton(checkboxWithTitle: "Title transcripts from calendar events", target: nil, action: nil)
    private let loginBtn = NSButton(checkboxWithTitle: "Start at login (24/7 recording)", target: nil, action: nil)
    private let systemAudioBtn = NSButton(checkboxWithTitle: "Capture system audio (other participants)", target: nil, action: nil)
    private var runningAppIds: [String] = []

    private let segValues = [900, 1800, 3600, 7200], segTitles = ["15 min", "30 min", "1 hour", "2 hours"]
    private let langValues = ["auto", "ko", "ja", "en"], langTitles = ["Auto-detect", "Korean", "Japanese", "English"]
    private let modelNames = WhisperCatalog.all.map { $0.name }   // popup order matches WhisperCatalog.all
    private let retValues = [7, 30, 90, 0], retTitles = ["7 days", "30 days", "90 days", "Unlimited"]

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "macrec — Settings"
        super.init(window: w)
        w.delegate = self
        buildForm()
        load()
        w.setContentSize(NSSize(width: 600, height: 520))   // roomy fixed size; form top, buttons bottom
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func labeled(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.alignment = .right; return l }

    private func buildForm() {
        segPopup.addItems(withTitles: segTitles); langPopup.addItems(withTitles: langTitles)
        modelPopup.addItems(withTitles: WhisperCatalog.all.map { $0.label })
        audioRetPopup.addItems(withTitles: retTitles); txtRetPopup.addItems(withTitles: retTitles)
        for f in [voiceField, dirField, audioDirField] { f.translatesAutoresizingMaskIntoConstraints = false }
        voiceField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        dirField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        audioDirField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        excludeTokens.translatesAutoresizingMaskIntoConstraints = false
        excludeTokens.tokenizingCharacterSet = CharacterSet(charactersIn: ", ")
        excludeTokens.placeholderString = "e.g. com.spotify.client"
        excludeTokens.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        populateRunningApps()

        let chooseBtn = NSButton(title: "Choose…", target: self, action: #selector(chooseDir))
        let dirStack = NSStackView(views: [dirField, chooseBtn]); dirStack.orientation = .horizontal; dirStack.spacing = 6
        let audioChooseBtn = NSButton(title: "Choose…", target: self, action: #selector(chooseAudioDir))
        let audioStack = NSStackView(views: [audioDirField, audioChooseBtn]); audioStack.orientation = .horizontal; audioStack.spacing = 6

        let grid = NSGridView(views: [
            [labeled("Segment length (on the hour):"), segPopup],
            [labeled("Transcription language:"), langPopup],
            [labeled("Transcription model:"), modelPopup],
            [labeled("Min. speech (sec):"), voiceField],
            [labeled(""), vadBtn],
            [labeled(""), systemAudioBtn],
            [labeled(""), calBtn],
            [labeled(""), loginBtn],
            [labeled(""), keepAudioBtn],
            [labeled("Keep audio for:"), audioRetPopup],
            [labeled("Keep transcripts for:"), txtRetPopup],
            [labeled("Excluded apps:"), excludeTokens],
            [labeled("Add a running app:"), addAppPopup],
            [labeled("Save transcripts to:"), dirStack],
            [labeled("Save audio to:"), audioStack],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 16; grid.columnSpacing = 18
        grid.column(at: 0).xPlacement = .trailing

        let saveBtn = NSButton(title: "Save & Apply", target: self, action: #selector(saveAndClose)); saveBtn.keyEquivalent = "\r"
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(closeOnly)); cancelBtn.keyEquivalent = "\u{1b}"
        let btns = NSStackView(views: [cancelBtn, saveBtn]); btns.orientation = .horizontal; btns.spacing = 10
        btns.translatesAutoresizingMaskIntoConstraints = false

        // Form pinned to the TOP (natural row heights — no vertical stretch), buttons pinned to the
        // BOTTOM-trailing. Extra window height becomes empty space between them, not stretched rows.
        let content = NSView()
        content.addSubview(grid); content.addSubview(btns)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 34),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -34),
            btns.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 24),
            btns.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -34),
            btns.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
        ])
        window?.contentView = content
    }

    /// Fill the "add a running app" popup with currently-running regular apps (name + bundle id).
    private func populateRunningApps() {
        addAppPopup.removeAllItems()
        addAppPopup.addItem(withTitle: "＋ Choose an app…")
        runningAppIds = [""]
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.localizedName != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for a in apps {
            addAppPopup.addItem(withTitle: "\(a.localizedName!)  (\(a.bundleIdentifier!))")
            runningAppIds.append(a.bundleIdentifier!)
        }
        addAppPopup.target = self
        addAppPopup.action = #selector(addApp)
    }

    @objc private func addApp() {
        let i = addAppPopup.indexOfSelectedItem
        guard i > 0, i < runningAppIds.count else { return }
        let bid = runningAppIds[i]
        var cur = (excludeTokens.objectValue as? [String]) ?? []
        if !cur.contains(bid) { cur.append(bid); excludeTokens.objectValue = cur }
        addAppPopup.selectItem(at: 0)
    }

    private func idx<T: Equatable>(_ v: T, _ arr: [T]) -> Int { arr.firstIndex(of: v) ?? 0 }

    private func load() {
        let c = EngineConfig.load()
        segPopup.selectItem(at: idx(Int(c.segmentSeconds), segValues))
        langPopup.selectItem(at: idx(c.whisperLang, langValues))
        modelPopup.selectItem(at: idx(WhisperCatalog.selected.name, modelNames))
        voiceField.stringValue = String(Int(c.voiceMinSeconds))
        vadBtn.state = c.vadEnabled ? .on : .off
        systemAudioBtn.state = Pref.bool(Pref.systemAudio, "MR_SYSTEM_AUDIO", true) ? .on : .off
        calBtn.state = c.useCalendarTitles ? .on : .off
        keepAudioBtn.state = c.keepAudio ? .on : .off
        audioRetPopup.selectItem(at: idx(c.audioRetentionDays, retValues))
        txtRetPopup.selectItem(at: idx(c.transcriptRetentionDays, retValues))
        excludeTokens.objectValue = c.excludeBundleIds
        dirField.stringValue = c.transcriptsDir.path
        audioDirField.stringValue = c.audioDir.path
        // Start at login — read the live SMAppService status (never cache); locked on the dev machine.
        if #available(macOS 13, *) {
            if LoginItem.managedByLaunchAgent {
                loginBtn.state = .on; loginBtn.isEnabled = false
                loginBtn.toolTip = "Managed by the LaunchAgent on this machine."
            } else {
                switch LoginItem.status {
                case .enabled:          loginBtn.state = .on;  loginBtn.toolTip = nil
                case .requiresApproval: loginBtn.state = .on;  loginBtn.toolTip = "Pending — enable in System Settings ▸ Login Items."
                default:                loginBtn.state = .off; loginBtn.toolTip = nil   // .notRegistered / .notFound
                }
            }
        } else { loginBtn.isEnabled = false }
    }

    @objc private func chooseDir() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { dirField.stringValue = u.path }
    }
    @objc private func chooseAudioDir() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { audioDirField.stringValue = u.path }
    }

    @objc private func saveAndClose() {
        let d = Pref.d
        d.set(Double(segValues[max(0, segPopup.indexOfSelectedItem)]), forKey: Pref.segment)
        d.set(langValues[max(0, langPopup.indexOfSelectedItem)], forKey: Pref.lang)
        d.set(modelNames[max(0, modelPopup.indexOfSelectedItem)], forKey: Pref.model)
        d.set(Double(Int(voiceField.stringValue) ?? 5), forKey: Pref.voiceMin)
        d.set(vadBtn.state == .on, forKey: Pref.vad)
        d.set(systemAudioBtn.state == .on, forKey: Pref.systemAudio)
        d.set(calBtn.state == .on, forKey: Pref.cal)
        d.set(keepAudioBtn.state == .on, forKey: Pref.keepAudio)
        d.set(retValues[max(0, audioRetPopup.indexOfSelectedItem)], forKey: Pref.audioRetention)
        d.set(retValues[max(0, txtRetPopup.indexOfSelectedItem)], forKey: Pref.txtRetention)
        let ids = (excludeTokens.objectValue as? [String]) ?? []
        d.set(ids.joined(separator: " "), forKey: Pref.exclude)
        d.set(dirField.stringValue, forKey: Pref.txtDir)
        d.set(audioDirField.stringValue, forKey: Pref.audioDir)
        // Apply "Start at login" (skip on the dev machine where the LaunchAgent owns autostart).
        if #available(macOS 13, *), !LoginItem.managedByLaunchAgent {
            if LoginItem.setEnabled(loginBtn.state == .on) == .requiresApproval { LoginItem.openSettings() }
        }
        window?.close()
        onSave()
    }
    @objc private func closeOnly() { window?.close() }
}

// MARK: - login-item autostart (SMAppService)

/// Auto-start at login via the modern Login Item API (macOS 13+). Works for our self-signed,
/// /Applications-installed app because the signature is a stable cert-based DR. On the developer's
/// machine the install.sh LaunchAgent owns autostart, so we detect it and stay out of the way.
enum LoginItem {
    /// The dev LaunchAgent (install.sh). When present, launchd owns autostart — not us.
    static var managedByLaunchAgent: Bool {
        let p = ("~/Library/LaunchAgents/com.ikhoon.meeting-recorder.plist" as NSString).expandingTildeInPath
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

    /// First-run only: enable autostart for the DISTRIBUTED app (no LaunchAgent, running from
    /// /Applications, never registered before). A one-shot flag means a later user opt-out in
    /// System Settings is never silently overridden.
    static func autoEnableOnceIfDistributed() {
        guard #available(macOS 13, *) else { return }
        guard !managedByLaunchAgent else { return }                         // dev machine: launchd owns it
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { return }  // stable location only
        guard !Pref.d.bool(forKey: Pref.autostartOffered) else { return }   // only ever auto-enable once
        Pref.d.set(true, forKey: Pref.autostartOffered)
        guard status == .notRegistered else { return }                      // never touch a prior user choice
        _ = setEnabled(true)
        elog("login item: auto-enabled on first run (status=\(status))")
    }
}

// MARK: - menu-bar app (tray icon)

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var engine: RecordingEngine?
    private var statusLine: NSMenuItem!
    private var levelItem: NSMenuItem!
    private var lastSavedLine: NSMenuItem!
    private var modelLine: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var paused = false
    private var settingsWC: SettingsWindowController?
    private var levelTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: if a copy is already running (the LaunchAgent one), just tell it to open
        // its menu and quit this launch — so clicking the app in /Applications opens the tray menu.
        let bid = Bundle.main.bundleIdentifier ?? "com.ikhoon.meeting-capture"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(
                .init("com.ikhoon.MeetingRecorder.openMenu"), object: nil, deliverImmediately: true)
            NSApp.terminate(nil); return
        }
        buildMenu()
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.ikhoon.MeetingRecorder.openMenu"), object: nil, queue: .main
        ) { [weak self] _ in self?.openMenu() }
        CalendarLookup.requestAccess()   // one-time Calendar prompt (for titling transcripts)
        setupModelDownload()             // first-run: fetch the large model, show progress in the menu
        LoginItem.autoEnableOnceIfDistributed()   // distributed app: enable 24/7 autostart on first run
        startEngine()
        installStopHandler { [weak self] in
            if let eng = self?.engine {
                let s = DispatchSemaphore(value: 0)
                Task { await eng.stop(); s.signal() }
                _ = s.wait(timeout: .now() + 15)
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func setIcon(recording: Bool) {
        // Distinct audio-recorder identity: a waveform-with-mic while live, pause when not.
        let primary = recording ? "waveform.badge.mic" : "pause.circle"
        let fallback = recording ? "waveform" : "pause"
        // Fixed point size so the menu-bar icon never resizes (independent of which symbol).
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let img = (NSImage(systemSymbolName: primary, accessibilityDescription: "macrec")
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: "macrec"))?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.length = 30   // fixed width — our item won't reflow as system indicators come/go
        elog("icon set (recording=\(recording)), statusItem.length=\(statusItem.length)")
    }

    private func item(_ title: String, _ sel: Selector, _ key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key); i.target = self; return i
    }

    private func buildMenu() {
        setIcon(recording: false)
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: ""); statusLine.isEnabled = false
        levelItem = NSMenuItem(title: "🎤 —   🔊 —", action: nil, keyEquivalent: ""); levelItem.isEnabled = false
        lastSavedLine = NSMenuItem(title: "", action: nil, keyEquivalent: ""); lastSavedLine.isEnabled = false; lastSavedLine.isHidden = true
        modelLine = NSMenuItem(title: "", action: nil, keyEquivalent: ""); modelLine.isEnabled = false; modelLine.isHidden = true
        menu.addItem(statusLine); menu.addItem(levelItem); menu.addItem(lastSavedLine); menu.addItem(modelLine)
        menu.addItem(.separator())
        // Custom-view button so clicking it does NOT dismiss the menu — you can watch the live
        // meter + status update in place while it transcribes.
        let tItem = NSMenuItem()
        let tView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        let tBtn = NSButton(title: "Transcribe now", target: self, action: #selector(flushNow))
        tBtn.isBordered = false; tBtn.alignment = .left; tBtn.font = NSFont.menuFont(ofSize: 0)
        tBtn.frame = NSRect(x: 14, y: 1, width: 220, height: 20)
        tView.addSubview(tBtn); tItem.view = tView
        menu.addItem(tItem)
        toggleItem = item("Pause", #selector(togglePause)); menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), ","))
        menu.addItem(item("Open transcripts folder", #selector(openTranscripts), "o"))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    // Live input meter — only updates while the menu is open (cheap, and answers "is it working?").
    func menuWillOpen(_ menu: NSMenu) {
        updateLevels()
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
        toggleItem?.title = paused ? "Resume" : "Pause"
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
            DispatchQueue.main.async { if self?.paused == false { self?.statusLine.title = "● \(msg)" } }
        }
        eng.onTranscriptSaved = { [weak self] msg in
            DispatchQueue.main.async {
                self?.lastSavedLine.title = "✓ \(msg)"; self?.lastSavedLine.isHidden = false
                if self?.paused == false { self?.statusLine.title = "● Recording · mic + system audio" }
            }
        }
        engine = eng
        Task {
            do {
                try await eng.start()
                await MainActor.run { self.paused = false; self.setIcon(recording: true); self.refresh("● Recording · mic + system audio") }
            } catch {
                await MainActor.run { self.engine = nil; self.setIcon(recording: false); self.refresh("⚠ Permission needed — enable 'meeting-capture' in System Settings") }
            }
        }
    }

    @objc private func flushNow() {
        guard engine != nil, !paused else { return }
        engine?.flushNow()
        refresh("● Transcribing now…")
    }

    @objc private func togglePause() {
        if paused {
            paused = false; refresh("Resuming…"); startEngine()
        } else {
            paused = true; setIcon(recording: false); refresh("⏸ Paused")
            if let eng = engine { engine = nil; Task { await eng.stop() } }
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
        Task {
            if let old = old { await old.stop() }
            await MainActor.run { self.startEngine() }
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

    @objc private func quit() {
        if let eng = engine {
            let s = DispatchSemaphore(value: 0)
            Task { await eng.stop(); s.signal() }
            _ = s.wait(timeout: .now() + 15)
        }
        NSApp.terminate(nil)
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
    let q = DispatchQueue(label: "meeting-recorder.signal")
    for s in [SIGINT, SIGTERM] {
        signal(s, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: s, queue: q)
        src.setEventHandler(handler: handler)
        src.resume()
        signalSources.append(src)
    }
}

// MARK: - main

@main
struct Main {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())

        // Subcommand: mic-status — is the default input device currently in use?
        if args.first == "mic-status" {
            print(micStatus() ? "1" : "0")
            exit(0)
        }

        // Subcommand: config — print the loaded settings (UserDefaults > env > default) and exit.
        if args.first == "config" {
            let c = EngineConfig.load()
            print("suite=\(Pref.suiteName)")
            print("segmentSeconds=\(Int(c.segmentSeconds)) voiceMin=\(Int(c.voiceMinSeconds)) lang=\(c.whisperLang) vad=\(c.vadEnabled) keepAudio=\(c.keepAudio) audioRetDays=\(c.audioRetentionDays) txtRetDays=\(c.transcriptRetentionDays)")
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

        // Subcommand: perm-status — are both Screen Recording and Microphone granted? (no prompt)
        if args.first == "perm-status" {
            let ok = hasScreenPermission() && micAuthorized()
            print(ok ? "1" : "0")
            exit(ok ? 0 : 1)
        }

        // Subcommand: request-permission — prompt for / register both permissions. Never hangs.
        if args.first == "request-permission" {
            let p = requestPermissions()
            elog("screen-recording=\(p.screen) microphone=\(p.mic)")
            print(p.screen && p.mic ? "1" : "0")
            exit(p.screen && p.mic ? 0 : 3)
        }

        // Subcommand: register — force this binary into the TCC lists by actually attempting an
        // SCStream capture (the reliable way to get listed under Screen Recording). A 3s watchdog
        // exits the process so a not-yet-granted startCapture() can't hang forever.
        if args.first == "register" {
            _ = CGRequestScreenCaptureAccess()
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            DispatchQueue.global().asyncAfter(deadline: .now() + 25) { exit(0) }  // watchdog (keep prompt alive)
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                if let d = content.displays.first {
                    let f = SCContentFilter(display: d, excludingApplications: [], exceptingWindows: [])
                    let c = SCStreamConfiguration()
                    c.capturesAudio = true
                    c.width = 2; c.height = 2
                    let s = SCStream(filter: f, configuration: c, delegate: nil)
                    try await s.startCapture()
                    try? await s.stopCapture()
                }
            } catch { elog("register attempt: \(error)") }
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
        var excludeBundleIds: [String] = []   // 오디오에서 제외할 앱 bundle id (예: Spotify)
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

        // Preflight permissions. Calling startCapture() without Screen Recording permission
        // hangs forever under a background launchd agent (it blocks on a prompt that never shows).
        guard hasScreenPermission() else {
            elog("error: Screen Recording permission not granted. Run `meeting-capture request-permission`, then enable meeting-capture in System Settings → Screen & System Audio Recording.")
            _ = requestPermissions()
            exit(3)
        }
        guard noMic || micAuthorized() else {
            elog("error: Microphone permission not granted. Run `meeting-capture request-permission`, then enable meeting-capture in System Settings → Microphone.")
            _ = requestPermissions()
            exit(3)
        }

        do {
            let rec = Recorder(sysWriter: try SourceWriter(url: sysURL),
                               micWriter: noMic ? nil : try SourceWriter(url: micURL))

            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                elog("error: no display available for SCContentFilter")
                exit(1)
            }
            // 지정된 bundle id의 앱(들)을 오디오 캡처에서 제외한다. 한 bundle id가
            // 여러 헬퍼 프로세스를 가질 수 있으므로(예: Spotify) .filter 로 전부 모은다.
            // SCK는 앱 단위로 오디오를 거르므로 제외 앱의 소리는 sys 트랙에 안 섞인다.
            let excludedApps = content.applications.filter { excludeBundleIds.contains($0.bundleIdentifier) }
            if !excludedApps.isEmpty {
                elog("meeting-capture: excluding audio from \(excludedApps.map { $0.bundleIdentifier }.joined(separator: ", "))")
            }
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 4)  // ~4fps dummy video
            // No captureMicrophone / forced sampleRate — see CaptureSession note. Mic via MicCapture.

            let stream = SCStream(filter: filter, configuration: config, delegate: rec)
            rec.stream = stream
            try stream.addStreamOutput(rec, type: .screen, sampleHandlerQueue: rec.queue)
            try stream.addStreamOutput(rec, type: .audio, sampleHandlerQueue: rec.queue)
            let micCap = MicCapture()

            // Stop coordination via semaphore + signal sources.
            let sem = DispatchSemaphore(value: 0)
            let sigQ = DispatchQueue(label: "meeting-capture.signal")
            for s in [SIGINT, SIGTERM] {
                signal(s, SIG_IGN)
                let src = DispatchSource.makeSignalSource(signal: s, queue: sigQ)
                src.setEventHandler { sem.signal() }
                src.resume()
                signalSources.append(src)
            }

            try await stream.startCapture()
            if !noMic {
                do { try micCap.start(into: rec) }
                catch { elog("meeting-capture: mic capture failed: \(error)") }
            }
            elog("meeting-capture: recording → \(outPath)  (mic=\(!noMic))")
            if let duration = duration {
                sigQ.asyncAfter(deadline: .now() + duration) { sem.signal() }
            }

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    sem.wait()
                    cont.resume()
                }
            }

            elog("meeting-capture: stopping…")
            micCap.stop()
            try? await stream.stopCapture()
            rec.finalizeWriters()  // flush WAV headers before we read them back

            try mixDown(sysURL: sysURL, micURL: noMic ? nil : micURL, outURL: outURL)
            if !keepTemp {
                try? FileManager.default.removeItem(at: sysURL)
                if !noMic { try? FileManager.default.removeItem(at: micURL) }
            }

            elog("meeting-capture: done → \(outPath)")
            print(outPath)  // stdout = final mixed file path
            exit(0)
        } catch {
            elog("meeting-capture error: \(error)")
            try? FileManager.default.removeItem(at: sysURL)
            try? FileManager.default.removeItem(at: micURL)
            exit(1)
        }
    }
}
