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
    // Speech-RUN accounting: real speech holds above the threshold for ≥50 ms at a time; electrical
    // clicks/pops from a dead or misrouted input (the mic-less jack incident: hours of segments
    // "voiced" by clicks, every one transcribing to nothing) never form such runs.
    static let speechRunFrames = 800             // 50 ms @ 16 kHz
    var speechFrames: AVAudioFramePosition = 0   // samples inside ≥50 ms voiced runs
    private var voicedRun = 0                    // current contiguous run length

    /// Seconds of "voiced" (above-threshold) audio — used to decide if a segment is worth transcribing.
    var voicedSeconds: Double { Double(voicedFrames) / canon.sampleRate }
    /// Seconds inside sustained (speech-length) voiced runs — near zero for click/pop-only audio.
    var speechSeconds: Double { Double(speechFrames) / canon.sampleRate }

    var stats: String {
        let secs = Double(framesOut) / canon.sampleRate
        return String(format: "%@: %.1fs peak=%.4f voiced=%.1fs speech=%.1fs buffersIn=%d convErrors=%d srcRate=%.0f",
                      url.lastPathComponent, secs, peak, voicedSeconds, speechSeconds, buffersIn, convErrors, srcFormat?.sampleRate ?? 0)
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
        append(inBuf)
    }

    /// Convert an arbitrary-format PCM buffer to canonical 16 kHz mono float32 and write it.
    /// (System audio arrives here from the Core Audio tap; mic from AVCaptureSession via a CMSampleBuffer.)
    func append(_ inBuf: AVAudioPCMBuffer) {
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
                if a > SourceWriter.voiceThreshold {
                    voicedFrames += 1
                    voicedRun += 1
                    if voicedRun == SourceWriter.speechRunFrames {
                        speechFrames += AVAudioFramePosition(voicedRun)   // run qualified — count it all
                    } else if voicedRun > SourceWriter.speechRunFrames {
                        speechFrames += 1
                    }
                } else {
                    voicedRun = 0
                }
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

// MARK: - echo canceller (opt-in speaker→mic echo reduction via SpeexDSP AEC)
//
// When the far-end plays through SPEAKERS it leaks into the mic and gets transcribed a second time under
// the mic speaker. Apple's voice-processing AEC can't help (it only cancels audio THIS process renders;
// the far-end is another app's output). Instead we run a real adaptive echo canceller (SpeexDSP) with the
// process-tap system audio as the REFERENCE and the mic as the near-end — it subtracts the echo while
// preserving the user's own voice, even during double-talk. libspeexdsp is statically linked
// (see speex-bridge.h + install.sh), so the .app stays self-contained. Opt-in (default off).
//
// Two invariants keep the canceller effective (both found by adversarial review, not obvious):
//  1. STALENESS — the reference fed to speex must not lag the mic by more than the real speaker→mic
//     delay, or the causal filter cancels nothing; every drain trims the ring to ≤ maxLag staleness.
//  2. FRESHNESS ACROSS GAPS — after the mic goes silent (pause/sleep/toggle/restart), buffered residue
//     and the adapted filter belong to a dead stream; cancelMic self-heals by resetting on a >0.5 s gap.
final class EchoCanceller {
    static let shared = EchoCanceller()
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let frame = 256           // 16 ms @ 16 kHz — SpeexDSP fixed processing frame
    private let filter = 8192         // ~512 ms adaptive tail — external DACs/speakers add latency, and a
                                      // longer tail also models more of the room's reverb (deeper ERLE)
    private let maxRef = 8192         // push-side ring cap — memory bound while the mic is stalled. Must
                                      // cover ≥ gapNs of reference: a stall short of the gap-heal reset
                                      // (< 0.5 s) must never hit this cap, or the FIFO silently loses
                                      // reference and shifts the pairing offset without a filter reset.
    // Max reference STALENESS (samples) left in the ring after each drain. Speex's filter is CAUSAL: it
    // only cancels echo whose reference it has already been fed, so the fed reference must not lag the mic
    // by more than the real speaker→mic delay (~40–150 ms). Capture starts the tap BEFORE the mic, so the
    // ring pre-fills during mic spin-up — and since fill and drain rates are both 16 kHz, that backlog would
    // otherwise persist for the whole session and silently disable the AEC (reference too old → cancels 0 dB).
    private let maxLag = 512          // ~32 ms
    private let gapNs: UInt64 = 500_000_000   // mic silent this long → treat buffered state as a dead stream
    private let refLock = NSLock()    // guards refRing ONLY (kept tiny: it sits between the tap and mic paths)
    private let convLock = NSLock()   // guards refConv (conversion runs OUTSIDE refLock so the mic never waits on it)
    private let stateLock = NSLock()  // serializes cancelMic/reset (micBuf, micConv, st): capture sessions can
                                      // briefly OVERLAP on pause→quick-resume, so two mic queues may call in
    private var refRing = [Int16]()   // far-end reference, 16k mono, FIFO
    private var refConv: AVAudioConverter?
    private var micConv: AVAudioConverter?
    private var micBuf = [Int16]()    // mic samples awaiting a full frame (or its reference)
    private var st: OpaquePointer?    // Speex echo-canceller state
    private var pp: OpaquePointer?    // Speex preprocessor — residual echo suppression bound to st
    private var lastMicNs: UInt64 = 0 // uptime of the previous cancelMic (gap detection)
    private var anchored = false      // first drain after reset sets the FIFO pairing offset
    private var winMinDepth = Int.max // min post-drain ring depth in the current re-anchor window
    private var winProcessed = 0      // AUDIO time in the window (processed samples) — deterministic,
    private let winSamples = 16000 * 5   // independent of wall-clock/scheduling (and of test speed)
    // Reusable work buffers (stateLock-guarded) — the mic path runs ~100×/s; keep it allocation-free.
    private var wkMic = [Int16](), wkRef = [Int16](), wkOut = [Int16](), wkClean = [Int16](), wkSnap = [Int16]()

    var enabled: Bool { Pref.bool(Pref.echoReduce, "MR_ECHO_REDUCE", false) }
    // Opt-in diagnostics (`defaults write com.ikhoon.macrec echoDebug -bool true`): logs the AEC's
    // cumulative in/out + reference-ring depth so echo behaviour can be tuned against a real call.
    private var debug: Bool { Pref.bool("echoDebug", "MR_ECHO_DEBUG", false) }

    /// Clear buffered audio + reset the adaptive filter. Thread-safe.
    func reset() { stateLock.lock(); resetLocked(); stateLock.unlock() }
    private func resetLocked() {   // caller holds stateLock
        refLock.lock(); refRing.removeAll(keepingCapacity: true); refLock.unlock()
        micBuf.removeAll(keepingCapacity: true)
        lastMicNs = 0
        anchored = false; winMinDepth = .max; winProcessed = 0
        dbgMicE = 0; dbgOutE = 0   // ERLE must reflect only the CURRENT stream (metric guides tuning)
        if let st { speex_echo_state_reset(st) }
        // The preprocessor has no reset API — recreate so its noise/echo estimates don't span streams.
        if let pp { speex_preprocess_state_destroy(pp); self.pp = nil }
        if let st { makePreprocessor(for: st) }
    }

    /// Feed a system-audio (reference) buffer — 16k mono Int16 into the ring (tap thread).
    func pushReference(_ buf: AVAudioPCMBuffer) {
        convLock.lock()                               // conversion off refLock — the mic path never waits on it
        let s = to16kInt16(buf, &refConv)
        convLock.unlock()
        guard let s else { return }
        refLock.lock()
        refRing.append(contentsOf: s)
        if refRing.count > maxRef { refRing.removeFirst(refRing.count - maxRef) }
        refLock.unlock()
    }

    // Selftest hooks — buffered depths (not part of the audio path).
    var refDepthForTest: Int { refLock.lock(); defer { refLock.unlock() }; return refRing.count }
    var micDepthForTest: Int { stateLock.lock(); defer { stateLock.unlock() }; return micBuf.count }

    /// Echo-cancel the mic against the buffered reference; returns cleaned 16k mono float (capture thread).
    /// May return fewer samples than the input (frame buffering) or 0 while filling the first frame.
    func cancelMic(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        stateLock.lock()
        defer { stateLock.unlock() }
        // After a mic gap (session (re)start, pause→resume, sleep/wake, device switch, toggle-on) the
        // buffered residue and the adaptive filter belong to a DEAD stream: stale micBuf samples would be
        // injected into the new recording and the filter starts converged to the wrong echo path. Start clean.
        let now = DispatchTime.now().uptimeNanoseconds
        if debug, lastMicNs != 0 {
            let gapMs = Double(now &- lastMicNs) / 1e6
            if gapMs > 30 { elog("echo-diag MICSTALL gap=\(Int(gapMs))ms") }
        }
        if lastMicNs == 0 || now &- lastMicNs > gapNs { resetLocked() }
        lastMicNs = now
        guard let mic16 = to16kInt16(pcm, &micConv) else { return nil }
        ensureState()
        guard let st else { return nil }   // init failed → fall back to raw mic
        micBuf.append(contentsOf: mic16)
        // Reuse the work buffers (see wk*) — steady-state processing stays allocation-free.
        if wkMic.count != frame {
            wkMic = .init(repeating: 0, count: frame); wkRef = wkMic; wkOut = wkMic
        }
        wkClean.removeAll(keepingCapacity: true); wkClean.reserveCapacity(micBuf.count)
        // FIFO pairing with a CONTINUOUS reference is everything here: as long as we neither trim nor
        // zero-pad, delivery jitter only changes WHEN samples get processed, never WHICH samples pair —
        // the offset stays constant and the adaptive filter converges. (The previous policy trimmed on
        // instantaneous depth, which fired ~13×/s against a mic that naturally delivers in ~32 ms clumps,
        // shredding the reference and pinning measured ERLE at ~6 dB.)
        let nFrames = micBuf.count / frame
        if nFrames > 0 {
            wkSnap.removeAll(keepingCapacity: true)
            var zeroPad = 0
            refLock.lock()
            if !anchored {
                // One-shot anchor on a stream's first drain: ring content beyond maxLag is startup
                // backlog (the tap starts before the mic) — dropping it sets the pairing offset.
                let excess = refRing.count - (nFrames * frame + maxLag)
                if excess > 0 { refRing.removeFirst(excess); dbgTrim &+= excess }
                anchored = true
                winProcessed = 0; winMinDepth = .max
            }
            // Process only reference-covered frames; hold the rest for the next call (the ring refills
            // within ~11 ms). If the reference is genuinely absent (system audio off, tap dead) don't
            // let the mic back up — flush the backlog zero-padded; those frames carry no echo anyway.
            var nProc = min(nFrames, refRing.count / frame)
            if nProc < nFrames && micBuf.count - nProc * frame > frame * 4 { nProc = nFrames }
            let want = nProc * frame
            let refTake = min(want, refRing.count)
            if refTake > 0 { wkSnap.append(contentsOf: refRing[0..<refTake]); refRing.removeFirst(refTake) }
            zeroPad = want - refTake
            // Windowed-minimum re-anchor: the smallest post-drain depth over ~5 s is the persistent
            // pairing offset net of jitter. Only that excess is trimmed — transient clumps never are.
            // This catches real drift (clock skew, dropped mic buffers) without touching a healthy stream.
            winMinDepth = min(winMinDepth, refRing.count)
            winProcessed += want
            if winProcessed >= winSamples {
                if winMinDepth != .max, winMinDepth > maxLag {
                    let cut = min(winMinDepth - maxLag, refRing.count)
                    refRing.removeFirst(cut)
                    dbgTrim &+= cut
                    if debug { elog("echo-diag REANCHOR cut=\(cut)") }
                }
                winProcessed = 0; winMinDepth = .max
            }
            refLock.unlock()
            if zeroPad > 0 { dbgStarve &+= zeroPad; if debug { elog("echo-diag STARVE zeroPad=\(zeroPad)") } }
            for f in 0..<nProc {
                let m = f * frame
                for k in 0..<frame { wkMic[k] = micBuf[m + k] }
                for k in 0..<frame { let r = m + k; wkRef[k] = r < wkSnap.count ? wkSnap[r] : 0 }
                speex_echo_cancellation(st, &wkMic, &wkRef, &wkOut)   // (state, near-end/mic, far-end/ref, out)
                if let pp { speex_preprocess_run(pp, &wkOut) }        // residual echo suppression (bound to st)
                if debug {   // measured ERLE while the reference is active (does the AEC actually cancel?)
                    var me = 0.0, oe = 0.0, re = 0.0
                    for k in 0..<frame { me += Double(wkMic[k])*Double(wkMic[k]); oe += Double(wkOut[k])*Double(wkOut[k]); re += Double(wkRef[k])*Double(wkRef[k]) }
                    if re / Double(frame) > 1e5 { dbgMicE += me; dbgOutE += oe }
                }
                wkClean.append(contentsOf: wkOut)
            }
            if want > 0 { micBuf.removeFirst(want) }
        }
        if debug {   // cumulative counters (not per-call — per-call out aliases against the frame size)
            dbgN &+= 1; dbgIn &+= mic16.count; dbgOut &+= wkClean.count
            if dbgN % 90 == 0 {
                refLock.lock(); let rr = refRing.count; refLock.unlock()
                let erle = dbgMicE > 0 && dbgOutE > 0 ? String(format: "%.1f", 10 * log10(dbgMicE / dbgOutE)) : "n/a"
                elog("echo(speex): cumIn=\(dbgIn) cumOut=\(dbgOut) refRing=\(rr) micBuf=\(micBuf.count) trimmed=\(dbgTrim) erle=\(erle)dB")
                dbgMicE = 0; dbgOutE = 0
            }
        }
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, wkClean.count))) else { return nil }
        out.frameLength = AVAudioFrameCount(wkClean.count)
        if let ch = out.floatChannelData?[0] {
            for i in 0..<wkClean.count { ch[i] = Float(wkClean[i]) / 32768.0 }
        }
        return out
    }

    private var dbgN = 0, dbgIn = 0, dbgOut = 0                // debug counters (gated by `debug`)
    private var dbgTrim = 0, dbgStarve = 0                     // SAMPLES trimmed / zero-padded (not events) — health + selftest
    private var dbgMicE = 0.0, dbgOutE = 0.0                   // ERLE accumulators (ref-active frames only)
    // Selftest hooks — cumulative SAMPLE counts; a healthy stream must add zero to either
    // (see the jitter regression test).
    var trimsForTest: Int { stateLock.lock(); defer { stateLock.unlock() }; return dbgTrim }
    var starvesForTest: Int { stateLock.lock(); defer { stateLock.unlock() }; return dbgStarve }
    // Invariant hook: the push cap must cover ≥ gapNs of reference — a stall shorter than the gap-heal
    // reset must never hit the cap (it would silently shift the pairing offset without a filter reset).
    var capCoversGapForTest: Bool { Double(maxRef) / 16000.0 >= Double(gapNs) / 1e9 }
    private func ensureState() {
        guard st == nil else { return }
        guard let s = speex_echo_state_init(Int32(frame), Int32(filter)) else {
            elog("echo(speex): echo-state init FAILED — falling back to raw mic")   // cancelMic guards on st == nil
            return
        }
        var rate: Int32 = 16000
        speex_echo_ctl(s, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
        st = s
        makePreprocessor(for: s)
        if debug { elog("echo(speex): AEC initialized (frame=\(frame) filter=\(filter) pp=\(pp != nil))") }
    }

    /// Residual echo suppression: the linear AEC leaves an audible (transcribable) residue even when
    /// converged; the preprocessor, bound to the echo state, suppresses it below transcription level.
    private func makePreprocessor(for echoState: OpaquePointer) {
        if let pp { speex_preprocess_state_destroy(pp); self.pp = nil }   // never leak/overwrite a live state
        guard let p = speex_preprocess_state_init(Int32(frame), 16000) else {
            elog("echo(speex): preprocessor init failed — residual suppression disabled")
            return
        }
        guard speex_preprocess_ctl(p, SPEEX_PREPROCESS_SET_ECHO_STATE, UnsafeMutableRawPointer(echoState)) == 0 else {
            speex_preprocess_state_destroy(p)   // unbound preprocessor would silently skip suppression
            elog("echo(speex): preprocessor echo-state binding failed — residual suppression disabled")
            return
        }
        // Pin the feature set explicitly (defaults could drift across speexdsp versions): DENOISE stays
        // ON — residual echo suppression rides the same spectral-gain machinery, and a denoised mic
        // transcribes better; AGC/VAD/dereverb are OFF — level/detection changes are not this class's job.
        var on: Int32 = 1, off: Int32 = 0
        // Stronger-than-default residual suppression: the goal is stopping double-TRANSCRIPTION, and
        // whisper hears residuals that speex's defaults (-40/-15) consider inaudible. The active level
        // is what applies during double-talk — too strong and it starts shaving the user's own voice,
        // so both are tunable without a rebuild (defaults write com.ikhoon.macrec.prefs echoSuppress …).
        func dbKnob(_ key: String, _ env: String, _ def: Double) -> Int32 {   // NaN/inf/garbage-proof
            let v = Pref.dbl(key, env, def)
            return Int32(max(-100, min(0, v.isFinite ? v.rounded() : def)))  // attenuations are ≤ 0 dB
        }
        var suppress = dbKnob("echoSuppress", "MR_ECHO_SUPPRESS", -60)
        var suppressActive = dbKnob("echoSuppressActive", "MR_ECHO_SUPPRESS_ACTIVE", -30)
        speex_preprocess_ctl(p, SPEEX_PREPROCESS_SET_DENOISE, &on)
        speex_preprocess_ctl(p, SPEEX_PREPROCESS_SET_AGC, &off)
        speex_preprocess_ctl(p, SPEEX_PREPROCESS_SET_VAD, &off)
        speex_preprocess_ctl(p, SPEEX_PREPROCESS_SET_DEREVERB, &off)
        speex_preprocess_ctl(p, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS, &suppress)
        speex_preprocess_ctl(p, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE, &suppressActive)
        pp = p
    }

    /// Convert an arbitrary-format PCM buffer to 16 kHz mono Int16 (clamped).
    private func to16kInt16(_ buf: AVAudioPCMBuffer, _ conv: inout AVAudioConverter?) -> [Int16]? {
        let floatBuf: AVAudioPCMBuffer
        if buf.format == fmt { floatBuf = buf }
        else {
            if conv == nil || conv?.inputFormat != buf.format { conv = AVAudioConverter(from: buf.format, to: fmt) }
            guard let c = conv else { return nil }
            let ratio = fmt.sampleRate / buf.format.sampleRate
            let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
            guard let o = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
            var fed = false; var err: NSError?
            c.convert(to: o, error: &err) { _, s in if fed { s.pointee = .noDataNow; return nil }; fed = true; s.pointee = .haveData; return buf }
            guard err == nil, o.frameLength > 0 else { return nil }
            floatBuf = o
        }
        guard let fp = floatBuf.floatChannelData?[0] else { return nil }
        let n = Int(floatBuf.frameLength)
        var s = [Int16](repeating: 0, count: n)
        for i in 0..<n { let v = max(-1, min(1, fp[i])); s[i] = Int16(v * 32767) }
        return s
    }
}

// MARK: - recorder (holds the per-source writers)

final class Recorder {
    var sysWriter: SourceWriter?
    var micWriter: SourceWriter?
    let queue = DispatchQueue(label: "macrec.audio")

    init(sysWriter: SourceWriter?, micWriter: SourceWriter?) {
        self.sysWriter = sysWriter
        self.micWriter = micWriter
    }

    /// System audio arrives from the Core Audio tap (an owned copy — safe to hand to the queue).
    /// Live captions are fed straight from here (lowest latency — no WAV-write/canon-convert/queue hop).
    func appendSys(_ buf: AVAudioPCMBuffer) {
        if EchoCanceller.shared.enabled { EchoCanceller.shared.pushReference(buf) }   // reference for mic echo ducking
        if #available(macOS 26, *) { LiveCaptions.shared.feedSystem(buf) }
        queue.async { self.sysWriter?.append(buf) }
    }

    /// Mic samples arrive from a SEPARATE AVCaptureSession (independent of the system-audio tap), so
    /// the two capture paths don't interact. Appended on `queue` so it shares synchronization with
    /// sys writes and rotation swaps; live captions are fed directly (converted once) for low latency.
    func appendMic(_ sb: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sb), let pcm = SourceWriter.pcm(from: sb) else { return }
        // Opt-in: cancel speaker→mic echo via SpeexDSP (returns 16k-mono). Off = original raw PCM, zero overhead.
        let out = EchoCanceller.shared.enabled ? (EchoCanceller.shared.cancelMic(pcm) ?? pcm) : pcm
        if #available(macOS 26, *) { LiveCaptions.shared.feedMic(out) }
        queue.async { self.micWriter?.append(out) }
    }

    /// Drain in-flight callbacks, then release the AVAudioFiles so they flush their WAV headers
    /// to disk before mixdown reads them.
    func finalizeWriters() {
        queue.sync { }
        if let s = sysWriter {
            elog("stats sys " + s.stats)
            if s.framesOut > 16000 && s.peak < 0.001 {
                elog("⚠ system audio was SILENT (peak≈0) — other participants won't be transcribed. Check: (1) macrec has 'System Audio Recording Only' permission, (2) audio output routing (USB DAC / SoundSource).")
            }
        }
        if let m = micWriter { elog("stats mic " + m.stats) }
        sysWriter = nil
        micWriter = nil
    }
}

// MARK: - default-output guard
//
// Starting an AVCaptureSession with an audio input can, on some macOS versions, reset the system's
// DEFAULT OUTPUT device to the built-in speakers as a side effect — so you suddenly "can't hear"
// your meeting. (The system-audio tap itself uses a PRIVATE aggregate device pinned to the current
// output, so it does not change the default.) OutputKeeper (below) can re-pin the user's preferred
// output, but is DORMANT — we leave output routing entirely to macOS / SoundSource.

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
    private let q = DispatchQueue(label: "macrec.mic")
    private weak var recorder: Recorder?

    // Dropped mic buffers are otherwise INVISIBLE — but they shift the mic/reference alignment the
    // echo canceller depends on, so surface them while echo diagnostics are on (opt-in, no log spam).
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard Pref.bool("echoDebug", "MR_ECHO_DEBUG", false) else { return }
        elog("echo-diag MICDROP samples=\(CMSampleBufferGetNumSamples(sampleBuffer))")
    }

    func start(into rec: Recorder) throws {
        recorder = rec
        if session.inputs.isEmpty {   // configure once; idempotent so suspend→resume just toggles running
            guard let dev = AVCaptureDevice.default(for: .audio) else {
                throw NSError(domain: "macrec", code: 4, userInfo: [NSLocalizedDescriptionKey: "no default audio input device"])
            }
            // The one log line that would have named this incident immediately: hours of dead
            // segments traced to the default input being a mic-less external-jack device.
            elog("mic: capturing from '\(dev.localizedName)'")
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

    /// Best event overlapping [start, end] — prefers one with a Zoom/Meet/Teams link.
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
        func overlap(_ e: EKEvent) -> TimeInterval { max(0, min(e.endDate, end).timeIntervalSince(max(e.startDate, start))) }

        // An event caught only by the ±padding has zero true overlap: it belongs to the NEXT segment, and
        // since the event's start stamps the file name, keeping it makes two segments collide.
        let overlapping = events.filter { overlap($0) > 0 }
        guard !overlapping.isEmpty else { return nil }
        let chosen = overlapping.sorted { a, b in
            let la = link(a) != nil, lb = link(b) != nil
            if la != lb { return la }                 // events with a meeting link win
            return overlap(a) > overlap(b)            // else the one overlapping most
        }.first!
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
                let out = summaryOutputPath(transcriptPath: url.path,
                                            outDir: Pref.explicit(Pref.summaryOut, "MR_SUMMARY_OUT"))
                runPostProcessCommand(cmd) { status in
                    guard status != 0 else { SummaryStatus.shared.finished(file, at: Date(), output: out); return }
                    let why = reapFailedPostProcess(outPath: out)
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

    func started(_ file: String) { lock.lock(); activity = .running(file); lock.unlock() }
    func finished(_ file: String, at date: Date, output: String?) {
        lock.lock(); activity = .done(file, date); lastPath = output; lock.unlock()
    }
    func failed(_ file: String, at date: Date, reason: String?) {
        lock.lock(); activity = .failed(file, date, reason: reason); lock.unlock()
    }
    func resetForTest() { lock.lock(); activity = .idle; lastPath = nil; lock.unlock() }
}

/// A summary runner writes its STDOUT to `<out>.partial` and only then promotes it, so when it fails
/// the reason is inside that file, not on stderr — `claude` exiting 1 with "Not logged in · Please run
/// /login" left nothing but "exit 1" in the log. On failure, read the reason back and delete the orphan.
/// Returns the first line worth showing, if any. Pure enough to test: the path is injected.
@discardableResult
func reapFailedPostProcess(outPath: String, fs: FileManager = .default) -> String? {
    let partial = outPath + ".partial"
    defer { try? fs.removeItem(atPath: partial) }
    guard let data = fs.contents(atPath: partial),
          let text = String(data: data, encoding: .utf8) else { return nil }
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
final class FlippedDocView: NSView { override var isFlipped: Bool { true } }

/// A rounded, hairline-bordered settings group. Marker type so the UI selftest can count
/// "every pane renders at least one section card".
final class SectionCard: NSView {}

/// A wrapping label that wraps to its ACTUAL laid-out width instead of a fixed guess — so a one-line
/// description stays one line when the window is wide and only wraps when it truly runs out of room
/// (user: the "Capture system audio" note wrapped needlessly). Give it leading+trailing and it sizes
/// its own height correctly at any window width.
final class WrappingLabel: NSTextField {
    override func layout() {
        super.layout()
        if abs(preferredMaxLayoutWidth - bounds.width) > 0.5 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// A secondary wrapping caption (row descriptions, section notes) that self-sizes to its width.
func wrappingCaption(_ s: String, size: CGFloat = 11, color: NSColor = .secondaryLabelColor) -> WrappingLabel {
    let l = WrappingLabel(labelWithString: s)
    l.font = .systemFont(ofSize: size)
    l.textColor = color
    l.lineBreakMode = .byWordWrapping
    l.maximumNumberOfLines = 0
    l.cell?.wraps = true
    l.cell?.isScrollable = false
    l.translatesAutoresizingMaskIntoConstraints = false
    l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return l
}

/// Should a nested scroll view hand the wheel event to its parent instead of eating it? Yes when its
/// own content already fits (nothing to scroll), so hovering the pointer over an embedded editor no
/// longer traps the gesture and the whole pane can still scroll. Pure + unit-tested.
func nestedScrollPassesThrough(contentHeight: CGFloat, clipHeight: CGFloat) -> Bool {
    contentHeight <= clipHeight + 0.5
}

/// A scroll view that forwards vertical wheel events UP to the enclosing pane scroller when its own
/// content fits (so a prompt/calendar box with the pointer over it doesn't block scrolling the pane —
/// the pointer over a prompt box used to trap the gesture). When its content genuinely overflows it keeps the
/// event and scrolls itself.
final class PassthroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let contentH = documentView?.bounds.height ?? 0
        if nestedScrollPassesThrough(contentHeight: contentH, clipHeight: contentView.bounds.height) {
            nextResponder?.scrollWheel(with: event)   // let the pane scroll
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Sidebar row: a monochrome SF Symbol + label. The icon follows the row's background style —
/// muted (secondary) normally, white when the row is selected (the accent-filled state) — so the
/// nav reads as one clean column, not a wall of colored tiles (user + design-review feedback).
final class SidebarCell: NSTableCellView {
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { imageView?.contentTintColor = backgroundStyle == .emphasized ? .white : .secondaryLabelColor }
    }
}

/// Sidebar selection is app state, not focus state: it must look identical whether or not the table is
/// first responder. AppKit's own drawing consults focus, so we draw the pill ourselves.
final class SidebarRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set { }
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

/// Map a key-equivalent to the standard edit-action selector. Pure + unit-tested — ⌘V → `paste:`,
/// ⌘C → `copy:`, ⌘X → `cut:`, ⌘A → `selectAll:`, ⌘Z → `undo:`, ⌘⇧Z → `redo:`; nil for anything else
/// (the window then falls through to `super`). Requires the modifiers to match EXACTLY so ⌘⌥V etc.
/// aren't hijacked.
func standardEditSelector(key: String?, flags: NSEvent.ModifierFlags) -> Selector? {
    let k = key?.lowercased()
    if flags == .command {
        switch k {
        case "x": return #selector(NSText.cut(_:))
        case "c": return #selector(NSText.copy(_:))
        case "v": return #selector(NSText.paste(_:))
        case "a": return #selector(NSResponder.selectAll(_:))
        case "z": return Selector(("undo:"))
        default:  return nil
        }
    }
    if flags == [.command, .shift], k == "z" { return Selector(("redo:")) }
    return nil
}

/// A window that routes the standard edit shortcuts to the responder chain. An LSUIElement app has
/// no menu bar, so ⌘X/⌘C/⌘V/⌘A/⌘Z never reach a focused text field's field editor — pasting into
/// the Settings fields silently did nothing (user report). Dispatching the standard action selectors
/// via `sendAction(to: nil)` lands them on the field editor, which implements them.
final class EditableWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let sel = standardEditSelector(key: event.charactersIgnoringModifiers, flags: flags),
           NSApp.sendAction(sel, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Caption overlay panel: key-able despite `.nonactivatingPanel` (text selection needs key status),
/// and — since an LSUIElement app has no Edit menu to route key equivalents — ⌘C/⌘A are handled here.
final class CaptionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let tv = firstResponder as? NSTextView {
            switch event.charactersIgnoringModifiers {
            case "c": tv.copy(nil); return true
            case "a": tv.selectAll(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - update check (Sparkle-style UX, zero dependencies — GitHub Releases is the appcast)

/// Dotted-numeric version compare: "0.10.1" > "0.9.9" (string compare would say otherwise).
/// Missing components are zero; a leading "v" is tolerated. Pure + testable.
func isNewerVersion(_ candidate: String, than current: String) -> Bool {
    func parts(_ s: String) -> [Int] {
        s.trimmingCharacters(in: .whitespaces).lowercased()
            .split(separator: ".").map { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "v "))) ?? 0 }
    }
    let a = parts(candidate), b = parts(current)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
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

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSComboBoxDelegate {

    /// A field the parser can't read must LOOK broken while typing — schedule fields silently
    /// falling open to "record everything" is a privacy failure; a retention typo would silently
    /// keep the last saved period. Invalid input turns red and is ignored on save.
    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        if f === audioRawCombo || f === audioRetCombo { recolorRetentionCombos() }
    }

    fileprivate func recolorRetentionCombos() {
        for c in [audioRawCombo, audioRetCombo] {
            c.textColor = AudioArchivePolicy.parseRetentionDays(c.stringValue) != nil ? .labelColor : .systemRed
        }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { self.recolorRetentionCombos() }   // stringValue updates after this fires
    }
    private let onSave: () -> Void
    // Vertical navigation (System Settings style): a sidebar source list + one content pane at a
    // time, searchable. panesForTest doubles as the selftest hook (every pane must scroll etc.).
    private(set) var panesForTest: [(title: String, symbol: String, tint: NSColor, view: NSView, searchText: [String])] = []
    private let sidebarList = NSTableView()
    private let sidebarSearch = NSSearchField()
    private let paneContainer = NSView()
    private var visiblePaneIndexes: [Int] = []   // sidebar rows → pane indexes (search filters this)
    private var selectedPane = 0
    private var sectionGroupViews: [String: [NSView]] = [:]   // tag → section views, toggled as tabs
    private let segPopup = NSPopUpButton(), langPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let txtRetPopup = NSPopUpButton()
    private let audioRawCombo = NSComboBox(), audioRetCombo = NSComboBox()   // editable: any "45 days" works
    private let addAppPopup = NSPopUpButton()
    private let voiceField = NSTextField(), dirField = NSTextField(), audioDirField = NSTextField()
    private let customModelField = NSTextField()   // custom model URL or local path (overrides the popup)
    private let deepgramKeyField = NSSecureTextField()   // cloud live engines — the only off-device features
    private let openaiKeyField = NSSecureTextField()
    private let openaiBaseField = NSTextField()   // OpenAI-compatible proxy/gateway base URL ("" = official)
    private let gladiaKeyField = NSSecureTextField()
    private let postProcessField = NSTextField()  // freeform post-process command (shell mode)
    private let ppModeSeg = NSSegmentedControl()  // Off / Automatic summary (built-in) / Custom command
    private let ppModeValues = ["off", "summary", "shell"], ppModeTitles = ["Off", "Automatic summary", "Custom command"]
    private let runnerPopup = NSPopUpButton()     // which agent CLI writes the summary
    private let runnerValues = ["claude", "codex", "gemini"], runnerTitles = ["Claude CLI", "Codex CLI", "Gemini CLI"]
    private let promptView = NSTextView()         // summary prompt — a real TEXT AREA (prompts are sentences)
    private let promptFileField = NSTextField()   // external prompt file — overrides the text when readable
    private let promptScroll = PassthroughScrollView()   // its bordered, scrolling host (wheel passes to the pane when it fits)
    private let summaryOutField = NSTextField()   // summary output dir ("" = next to the transcript)
    private let dailyBtn = NSSwitch()
    private let dailyTimePicker = NSDatePicker()  // HH:mm the digest becomes due
    private let dailyOutField = NSTextField()     // digest output dir ("" = alongside the summaries)
    private let dailyNameField = NSTextField()    // digest file-name template ("" = "{date}.md")
    private let updateBtn = NSSwitch()
    private let dailyPromptView = NSTextView()    // digest prompt — same text-area treatment as summary
    private let dailyPromptScroll = PassthroughScrollView()
    private let dailyPromptFileField = NSTextField()
    /// One switch per live-caption engine. The overlay's picker offers an engine only when its switch is
    /// on AND the engine is ready (key present / binary installed) — see `selectableLiveEngines`.
    private let engineSwitches: [(engine: LiveEngine, box: NSSwitch)] =
        LiveEngine.allCases.map { ($0, NSSwitch()) }
    private let savedLabel = NSTextField(labelWithString: "✓ Saved")   // transient confirmation for a non-closing Save
    private var savedFlash: DispatchWorkItem?
    private var flashGen = 0                          // fences a stale fade-completion from hiding a newer flash
    private(set) var footerButtonsForTest: [NSButton] = []
    private let hintsTermsField = NSTextField()   // hint terms (comma/newline separated)
    private let hintsFileField = NSTextField()    // external hints file path
    private let schedBtn = NSSwitch()
    // Schedule is SELECTED, not typed (user, repeatedly): a 7-day multi-select + time-range pickers.
    private let daysSeg = NSSegmentedControl()          // Mon…Sun, multi-select (.selectAny)
    private let hoursRangesStack = NSStackView()        // one row per time range (start–end + remove)
    private weak var hoursControlView: NSView?          // the Hours control (rows + Add) — dimmed when off
    private let daySegKeys = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    private let hintsCalBtn = NSSwitch()
    private let excludeTokens = NSTokenField()   // multiple bundle ids as tokens
    // Calendar titling: a scrollable checkbox list of the user's calendars (none checked = all).
    private var calChecks: [(name: String, box: NSButton)] = []
    private let keepAudioBtn = NSSwitch()
    private let vadBtn = NSSwitch()
    private let calBtn = NSSwitch()
    private let loginBtn = NSSwitch()
    private let systemAudioBtn = NSSwitch()
    private let echoBtn = NSSwitch()
    private var runningAppIds: [String] = []

    private let segValues = [900, 1800, 3600, 7200], segTitles = ["15 min", "30 min", "1 hour", "2 hours"]
    private let langValues = ["auto", "ko", "ja", "en"], langTitles = ["Auto-detect", "Korean", "Japanese", "English"]
    private let transcriptLangPopup = NSPopUpButton()
    private let tLangValues = ["", "en", "ko", "ja"], tLangTitles = ["System", "English", "한국어", "日本語"]
    private let modelNames = WhisperCatalog.all.map { $0.name }   // popup order matches WhisperCatalog.all
    private let retValues = [7, 30, 90, 180, 365, 0]
    private let retTitles = ["7 days", "30 days", "90 days", "180 days", "1 year", "Unlimited"]

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
        let w = EditableWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
                               styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "macrec — Settings"
        super.init(window: w)
        w.delegate = self
        buildForm()
        load()
        // Fixed comfortable size (sidebar 200 + a 540pt content column). Panes taller than this
        // scroll, with a permanent scrollbar — no window auto-resizing (user ask).
        w.setContentSize(NSSize(width: 880, height: 600))
        selectPane(selectedPane)
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildForm() {
        segPopup.addItems(withTitles: segTitles); langPopup.addItems(withTitles: langTitles)
        transcriptLangPopup.addItems(withTitles: tLangTitles)
        modelPopup.addItems(withTitles: WhisperCatalog.all.map { $0.label })
        txtRetPopup.addItems(withTitles: retTitles)
        audioRawCombo.addItems(withObjectValues: ["3 days", "7 days", "14 days", "30 days", "Don't compress"])
        audioRetCombo.addItems(withObjectValues: ["30 days", "90 days", "180 days", "1 year", "Unlimited"])
        for c in [audioRawCombo, audioRetCombo] {
            c.translatesAutoresizingMaskIntoConstraints = false
            c.widthAnchor.constraint(equalToConstant: 140).isActive = true
            c.completes = true
            c.delegate = self   // red-on-invalid, same treatment as the schedule fields
        }
        for f in [voiceField, dirField, audioDirField, customModelField, deepgramKeyField, openaiKeyField, openaiBaseField, gladiaKeyField, postProcessField, promptFileField] { f.translatesAutoresizingMaskIntoConstraints = false }
        voiceField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        dirField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        audioDirField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        customModelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        customModelField.placeholderString = "https://…/ggml-model.bin  or  /path/to/model.bin"
        deepgramKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        deepgramKeyField.placeholderString = "Deepgram API key"
        openaiKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        openaiKeyField.placeholderString = "sk-…"
        openaiBaseField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        gladiaKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        gladiaKeyField.placeholderString = "Gladia API key"
        promptFileField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        promptFileField.placeholderString = "~/notes/summary-prompt.md"
        postProcessField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        postProcessField.placeholderString = "~/bin/my-pipeline.sh"
        summaryOutField.translatesAutoresizingMaskIntoConstraints = false
        summaryOutField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        summaryOutField.placeholderString = "empty = next to the transcript"
        dailyOutField.translatesAutoresizingMaskIntoConstraints = false
        dailyOutField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        dailyOutField.placeholderString = "empty = alongside the summaries"
        dailyNameField.translatesAutoresizingMaskIntoConstraints = false
        dailyNameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        dailyNameField.placeholderString = dailyDigestNameDefault
        dailyTimePicker.datePickerStyle = .textFieldAndStepper
        dailyTimePicker.datePickerElements = .hourMinute
        dailyTimePicker.translatesAutoresizingMaskIntoConstraints = false
        schedBtn.target = self; schedBtn.action = #selector(scheduleToggled)
        // Days: a 7-segment multi-select (Mon…Sun) — click to toggle, no typing, no invalid state.
        daysSeg.segmentCount = daySegKeys.count
        daysSeg.trackingMode = .selectAny
        daysSeg.segmentDistribution = .fillEqually
        daysSeg.translatesAutoresizingMaskIntoConstraints = false
        for (i, k) in daySegKeys.enumerated() { daysSeg.setLabel(k.capitalized, forSegment: i) }
        // Hours: a stack of time-range rows (start–end pickers + remove), plus an Add button below.
        hoursRangesStack.orientation = .vertical
        hoursRangesStack.alignment = .leading
        hoursRangesStack.spacing = 6
        hoursRangesStack.translatesAutoresizingMaskIntoConstraints = false
        for f in [hintsTermsField, hintsFileField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        hintsTermsField.placeholderString = "Kubernetes, gRPC, John Doe, …"
        hintsFileField.placeholderString = "~/notes/hints.txt"
        // PATH-carrying fields: a long path used to truncate at the TAIL, hiding the part that matters
        // (user report on "Save summary to"). Truncate the HEAD instead ("…/notes/summaries"), widen,
        // and mirror the full value into the tooltip on load (see load()).
        for f in [dirField, audioDirField, customModelField, hintsFileField, promptFileField,
                  summaryOutField, postProcessField] {
            f.cell?.lineBreakMode = .byTruncatingHead
            f.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        // Multiline prompt editor (user feedback: a one-line field is too small for a real prompt).
        promptScroll.translatesAutoresizingMaskIntoConstraints = false
        promptScroll.hasVerticalScroller = true
        promptScroll.autohidesScrollers = true
        promptScroll.borderType = .bezelBorder
        promptScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        promptScroll.heightAnchor.constraint(equalToConstant: 84).isActive = true
        promptView.isRichText = false
        promptView.font = .systemFont(ofSize: 12)
        promptView.textContainerInset = NSSize(width: 4, height: 6)
        promptView.autoresizingMask = [.width]
        promptView.isVerticallyResizable = true
        promptView.minSize = NSSize(width: 0, height: 0)
        promptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        promptView.textContainer?.widthTracksTextView = true
        promptScroll.documentView = promptView
        // Daily digest gets the SAME prompt affordances as the per-meeting summary (user ask).
        dailyPromptScroll.translatesAutoresizingMaskIntoConstraints = false
        dailyPromptScroll.hasVerticalScroller = true
        dailyPromptScroll.autohidesScrollers = true
        dailyPromptScroll.borderType = .bezelBorder
        dailyPromptScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        dailyPromptScroll.heightAnchor.constraint(equalToConstant: 66).isActive = true
        dailyPromptView.isRichText = false
        dailyPromptView.font = .systemFont(ofSize: 12)
        dailyPromptView.textContainerInset = NSSize(width: 4, height: 6)
        dailyPromptView.autoresizingMask = [.width]
        dailyPromptView.isVerticallyResizable = true
        dailyPromptView.minSize = NSSize(width: 0, height: 0)
        dailyPromptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        dailyPromptView.textContainer?.widthTracksTextView = true
        dailyPromptScroll.documentView = dailyPromptView
        dailyPromptFileField.translatesAutoresizingMaskIntoConstraints = false
        dailyPromptFileField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        dailyPromptFileField.placeholderString = "empty = the prompt above"
        ppModeSeg.segmentCount = ppModeTitles.count
        for (i, t) in ppModeTitles.enumerated() { ppModeSeg.setLabel(t, forSegment: i) }
        ppModeSeg.selectedSegment = 0
        ppModeSeg.segmentStyle = .texturedRounded
        ppModeSeg.target = self; ppModeSeg.action = #selector(ppModeChanged)
        runnerPopup.addItems(withTitles: runnerTitles)
        // Vendor badges on each runner so the picker reads at a glance (Claude / Codex / Gemini).
        let runnerBadges = [vendorBadge("sparkle", NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)),   // Claude — coral
                            vendorBadge("chevron.left.forwardslash.chevron.right", NSColor(srgbRed: 0.06, green: 0.64, blue: 0.50, alpha: 1)),  // Codex — OpenAI green
                            vendorBadge("sparkles", NSColor(srgbRed: 0.26, green: 0.52, blue: 0.96, alpha: 1))]  // Gemini — Google blue
        for (i, badge) in runnerBadges.enumerated() { runnerPopup.item(at: i)?.image = badge }
        openaiBaseField.placeholderString = "empty = api.openai.com"

        excludeTokens.translatesAutoresizingMaskIntoConstraints = false
        excludeTokens.tokenizingCharacterSet = CharacterSet(charactersIn: ", ")
        excludeTokens.placeholderString = "e.g. com.spotify.client"
        excludeTokens.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        populateRunningApps()

        let calListCell = buildCalendarList()
        let hoursControl = buildHoursControl()

        // One factory for every "path field + Choose…" row, so spacing and hugging can't drift.
        func pathStack(_ field: NSTextField, _ action: Selector) -> (stack: NSStackView, button: NSButton) {
            let b = NSButton(title: "Choose…", target: self, action: action)
            b.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let s = NSStackView(views: [field, b])
            s.orientation = .horizontal; s.spacing = 6; s.distribution = .fill
            return (s, b)
        }
        let dirStack = pathStack(dirField, #selector(chooseDir)).stack
        let audioStack = pathStack(audioDirField, #selector(chooseAudioDir)).stack
        let summaryStack = pathStack(summaryOutField, #selector(chooseSummaryDir)).stack
        let dailyStack = pathStack(dailyOutField, #selector(chooseDailyDir)).stack
        let promptFileStack = pathStack(promptFileField, #selector(choosePromptFile)).stack
        let dailyPromptFileStack = pathStack(dailyPromptFileField, #selector(chooseDailyPromptFile)).stack
        let hintsFileStack = pathStack(hintsFileField, #selector(chooseHintsFile)).stack
        // Switches read oversized next to 13pt row text — use the small control size so they sit in
        // proportion, like System Settings.
        for s in [systemAudioBtn, echoBtn, vadBtn, keepAudioBtn, schedBtn, dailyBtn, updateBtn, loginBtn, hintsCalBtn, calBtn]
                 + engineSwitches.map(\.box) {
            s.controlSize = .small
        }

        // ── Grouped row-card vocabulary (benchmarked to cmux / iTerm) ──
        // A pane is a list of Sections; a Section is an optional gray header + an intro note + a
        // rounded card of Rows. A Row is a title (+ optional description) on the LEFT and one control
        // on the RIGHT — or, for wide controls (text fields, path pickers, editors), the control
        // stacked full-width BELOW the title. Roles are explicit here, not derived from view types.
        struct Row { let name: String; let desc: String?; let control: NSView?; let wide: Bool }
        struct Section {
            let header: String?; let note: String?; let rows: [Row]; let group: String?; let icon: NSImage?
            // `group` tags a section so a control (e.g. the Summaries Mode segment) can show/hide it
            // as a real tab. nil = always visible. `icon` is an optional vendor badge shown before the header.
            init(header: String?, note: String?, rows: [Row], group: String? = nil, icon: NSImage? = nil) {
                self.header = header; self.note = note; self.rows = rows; self.group = group; self.icon = icon
            }
        }
        func r(_ name: String, _ control: NSView?, _ desc: String? = nil, wide: Bool = false) -> Row {
            Row(name: name, desc: desc, control: control, wide: wide)
        }
        // A boolean row: the switch is the right-hand control; its old checkbox title becomes the
        // row title (a switch carries no label of its own).
        func sw(_ b: NSSwitch, _ name: String, _ desc: String? = nil) -> Row {
            Row(name: name, desc: desc, control: b, wide: false)
        }

        // One row view: full-width, self-sizing. Inline layout for compact controls, stacked layout
        // (control below the text) for wide ones so a 340pt field never fights the title for width.
        // The description is pinned to its ACTUAL available trailing edge and wraps to that width —
        // so at a wide window it stays one line instead of wrapping at a fixed 300pt.
        func rowView(_ row: Row) -> NSView {
            let host = NSView(); host.translatesAutoresizingMaskIntoConstraints = false
            let name = NSTextField(labelWithString: row.name)
            name.font = .systemFont(ofSize: 13)
            name.textColor = .labelColor
            name.translatesAutoresizingMaskIntoConstraints = false
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            host.addSubview(name)
            let desc: WrappingLabel? = row.desc.map { wrappingCaption($0) }
            if let d = desc { host.addSubview(d) }
            var cs: [NSLayoutConstraint] = [
                name.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
                name.topAnchor.constraint(equalTo: host.topAnchor, constant: 11),
            ]
            // The x edge the text (name + desc) may extend to before hitting the control.
            let textTrailing: NSLayoutXAxisAnchor
            let textTrailingInset: CGFloat

            if let control = row.control {
                control.translatesAutoresizingMaskIntoConstraints = false   // every control is autolayout'd here
                // A row's name is a sibling label, and AppKit never infers a control's name from a view
                // that merely sits next to it. `NSButton(checkboxWithTitle:)` carried its own title, so
                // switching to NSSwitch/popups left every setting unlabelled to VoiceOver.
                if control.accessibilityLabel()?.isEmpty ?? true { control.setAccessibilityLabel(row.name) }
                host.addSubview(control)
                if row.wide {
                    // Title (+desc) on top, control stretched full-width beneath — fields fill the card.
                    control.setContentHuggingPriority(.defaultLow, for: .horizontal)
                    textTrailing = host.trailingAnchor; textTrailingInset = -14
                    let below = desc ?? name
                    cs += [
                        control.topAnchor.constraint(equalTo: below.bottomAnchor, constant: 8),
                        control.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
                        control.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
                        control.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -12),
                    ]
                } else {
                    // Title left, control right (centered); the text may extend up to the control.
                    control.setContentHuggingPriority(.required, for: .horizontal)
                    control.setContentCompressionResistancePriority(.required, for: .horizontal)
                    textTrailing = control.leadingAnchor; textTrailingInset = -14
                    let bottomAnchorView = desc ?? name
                    cs += [
                        control.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
                        control.centerYAnchor.constraint(equalTo: host.centerYAnchor),
                        bottomAnchorView.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -11),
                    ]
                }
            } else {
                textTrailing = host.trailingAnchor; textTrailingInset = -14
                let bottomAnchorView = desc ?? name
                cs += [bottomAnchorView.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -11)]
            }

            cs.append(name.trailingAnchor.constraint(lessThanOrEqualTo: textTrailing, constant: textTrailingInset))
            if let d = desc {
                cs += [
                    d.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
                    d.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
                    d.trailingAnchor.constraint(equalTo: textTrailing, constant: textTrailingInset),
                ]
            }
            NSLayoutConstraint.activate(cs)
            return host
        }

        // A rounded card holding rows separated by hairline dividers (dividers inset from the left,
        // matching the row text — the System Settings / cmux idiom).
        func card(_ rows: [Row]) -> SectionCard {
            let box = SectionCard()
            box.translatesAutoresizingMaskIntoConstraints = false
            box.wantsLayer = true
            box.layer?.cornerRadius = 8
            box.layer?.cornerCurve = .continuous
            box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            box.layer?.borderWidth = 1
            box.layer?.borderColor = NSColor.separatorColor.cgColor
            let stack = NSStackView()
            stack.orientation = .vertical; stack.spacing = 0; stack.alignment = .leading
            stack.translatesAutoresizingMaskIntoConstraints = false
            for (i, row) in rows.enumerated() {
                if i > 0 {
                    let div = NSBox(); div.boxType = .separator
                    div.translatesAutoresizingMaskIntoConstraints = false
                    stack.addArrangedSubview(div)
                    div.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14).isActive = true
                    div.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
                }
                let rv = rowView(row)
                stack.addArrangedSubview(rv)
                rv.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
                rv.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
            }
            box.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: box.topAnchor),
                stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            ])
            return box
        }

        // Collect every visible string in a pane for the sidebar search index (title + section
        // headers + notes + each row's name & description).
        func searchText(of title: String, _ sections: [Section]) -> [String] {
            var out = [title]
            for s in sections {
                if let h = s.header { out.append(h) }
                if let n = s.note { out.append(n) }
                for row in s.rows { out.append(row.name); if let d = row.desc { out.append(d) } }
            }
            return out.filter { !$0.isEmpty }
        }

        func pane(_ title: String, _ symbol: String, _ tint: NSColor, _ sections: [Section]) {
            let outer = NSStackView()
            outer.orientation = .vertical; outer.alignment = .leading; outer.spacing = 0
            outer.translatesAutoresizingMaskIntoConstraints = false

            let bigTitle = NSTextField(labelWithString: title)
            bigTitle.font = .systemFont(ofSize: 15, weight: .semibold)   // modest head — was 20pt, too shouty (user)
            bigTitle.textColor = .labelColor
            outer.addArrangedSubview(bigTitle)
            outer.setCustomSpacing(14, after: bigTitle)

            var fullWidth: [NSView] = []   // views that must stretch to the pane width
            for (si, s) in sections.enumerated() {
                var groupViews: [NSView] = []   // header+note+card of this section (for show/hide as a tab)
                if let h = s.header, h != title {   // skip a header that just echoes the pane title
                    let hl = NSTextField(labelWithString: h)   // normal case — not shouty all-caps (user)
                    hl.font = .systemFont(ofSize: 13, weight: .semibold)
                    hl.textColor = .secondaryLabelColor
                    let headerView: NSView
                    if let icon = s.icon {   // vendor badge before the name, for at-a-glance identity
                        let iv = NSImageView(image: icon)
                        iv.translatesAutoresizingMaskIntoConstraints = false
                        iv.widthAnchor.constraint(equalToConstant: 18).isActive = true
                        iv.heightAnchor.constraint(equalToConstant: 18).isActive = true
                        let hs = NSStackView(views: [iv, hl]); hs.orientation = .horizontal
                        hs.spacing = 7; hs.alignment = .centerY
                        headerView = hs
                    } else {
                        headerView = hl
                    }
                    outer.addArrangedSubview(headerView)
                    outer.setCustomSpacing(7, after: headerView)
                    groupViews.append(headerView)
                }
                if let n = s.note {
                    let nl = wrappingCaption(n)   // self-sizing: fills the pane width, wraps only if needed
                    outer.addArrangedSubview(nl)
                    outer.setCustomSpacing(s.rows.isEmpty ? 20 : 8, after: nl)
                    fullWidth.append(nl); groupViews.append(nl)
                }
                if !s.rows.isEmpty {
                    let c = card(s.rows)
                    outer.addArrangedSubview(c)
                    outer.setCustomSpacing(si == sections.count - 1 ? 0 : 20, after: c)
                    fullWidth.append(c); groupViews.append(c)
                }
                if let g = s.group { sectionGroupViews[g, default: []].append(contentsOf: groupViews) }
            }

            let doc = FlippedDocView()   // flipped so the form starts at the TOP of the scroll area
            doc.translatesAutoresizingMaskIntoConstraints = false
            doc.addSubview(outer)
            let scroll = NSScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .legacy     // a permanent scrollbar (user: always visible, not overlay)
            scroll.autohidesScrollers = false
            scroll.drawsBackground = false
            scroll.documentView = doc
            let paneView = NSView(); paneView.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: paneView.topAnchor),
                scroll.leadingAnchor.constraint(equalTo: paneView.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: paneView.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: paneView.bottomAnchor),
                doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                outer.topAnchor.constraint(equalTo: doc.topAnchor, constant: 22),
                outer.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 26),
                outer.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -26),
                outer.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -24),
            ])
            for v in fullWidth { v.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true }
            panesForTest.append((title: title, symbol: symbol, tint: tint, view: paneView,
                                 searchText: searchText(of: title, sections)))
        }
        // A concise reusable label for the "record around the clock" phrase.
        pane("Recording", "record.circle", .systemRed, [
            Section(header: "Capture", note: nil, rows: [
                r("Segment length", segPopup, "Starts a new recording file on the hour."),
                sw(systemAudioBtn, "Capture system audio", "Record other participants (system output), not only your mic."),
                sw(echoBtn, "Reduce mic echo", "Experimental — suppress speaker sound leaking back into the mic."),
                r("Minimum speech", voiceField, "Seconds of speech required before a segment is saved."),
                sw(vadBtn, "Remove noise & silence", "Voice-activity detection trims dead air from recordings."),
            ]),
            Section(header: "Excluded apps", note: nil, rows: [
                r("Never capture", excludeTokens, "These apps are left out of the recorded system-audio "
                  + "mix. They keep playing out loud, so your microphone may still pick them up.", wide: true),
                r("Add a running app", addAppPopup, wide: true),
            ]),
        ])
        pane("Schedule", "calendar.badge.clock", .systemOrange, [
            Section(header: "When to record", note: nil, rows: [
                sw(schedBtn, "Record only on a schedule", "Off = record around the clock."),
                r("Days", daysSeg, "Leave all off for every day.", wide: true),
                r("Hours", hoursControl, "The gap between two ranges is your lunch break; a range that "
                  + "ends before it starts wraps past midnight. No ranges = all hours.", wide: true),
            ]),
            Section(header: nil, note: "Off-hours the tray shows ⏸ Off-hours (schedule). A manual "
                    + "Pause/Resume overrides the schedule until its next boundary.", rows: []),
        ])
        pane("Storage", "archivebox", .systemBrown, [
            Section(header: "Transcripts", note: nil, rows: [
                r("Keep for", txtRetPopup),
                r("Folder", dirStack, wide: true),
            ]),
            Section(header: "Audio", note: nil, rows: [
                sw(keepAudioBtn, "Keep audio (WAV)", "Save the raw recording next to the transcript."),
                r("Compress after", audioRawCombo, "Recent recordings stay WAV; older ones archive to AAC "
                  + "(~⅛ the size). Type any period — 45 days, 6 months, 1 year."),
                r("Delete after", audioRetCombo, "Audio older than this is deleted, raw or compressed. "
                  + "Unlimited keeps it forever."),
                r("Folder", audioStack, wide: true),
            ]),
        ])
        pane("Transcription", "text.quote", .systemPurple, [
            Section(header: "Model", note: nil, rows: [
                r("Model", modelPopup),
                r("Custom model", customModelField, "A URL or path to a ggml model — overrides the picker above.", wide: true),
                r("Spoken language", langPopup, "The language whisper transcribes."),
                r("Transcript file language", transcriptLangPopup, "Headings and labels of the saved markdown file (not the speech)."),
            ]),
            Section(header: "Hints", note: nil, rows: [
                r("Terms", hintsTermsField, "Team/product names, jargon, people — comma or newline separated. "
                  + "Biases recognition so proper nouns stop coming out mangled.", wide: true),
                r("Hints file", hintsFileStack, "One term per line, # comments — merged with the terms above.", wide: true),
                sw(hintsCalBtn, "Add title & attendees from Calendar", "Feed the meeting's calendar event in as hints."),
            ]),
        ])
        pane("Titling", "textformat", .systemGreen, [
            Section(header: "Titling", note: "How each saved transcript is named.", rows: [
                sw(calBtn, "Title from calendar events", "Name transcripts after the meeting on your calendar."),
                r("Calendars", calListCell, "Checked calendars are matched; none checked = all of them.", wide: true),
            ]),
        ])
        pane("Summaries", "text.append", .systemIndigo, [
            Section(header: "Post-processing", note: "Runs after each hourly transcript is saved.", rows: [
                r("Mode", ppModeSeg, "Automatic summary is built in — pick who writes it, or take full "
                  + "control with a custom command.", wide: true),
            ]),
            // Mode is a tab: only the selected mode's sections show (see updatePostProcessEnabled).
            Section(header: nil, note: "Post-processing is off — transcripts are saved as-is.",
                    rows: [], group: "pp.off"),
            Section(header: "Automatic summary", note: nil, rows: [
                r("Summarize with", runnerPopup),
                r("Prompt", promptScroll, "Default asks for key points, decisions, and action items — "
                  + "answered in the transcript's language.", wide: true),
                r("Prompt file", promptFileStack, "Overrides the text above when readable — keep the prompt "
                  + "in your notes repo and iterate without opening Settings.", wide: true),
                r("Save summary to", summaryStack, "Summaries land in monthly folders (YYYY-MM/<name>.md). "
                  + "Empty = next to the transcript.", wide: true),
            ], group: "pp.summary"),
            Section(header: "Daily digest", note: nil, rows: [
                sw(dailyBtn, "Write a daily digest", "Roll the day's meeting summaries into one file."),
                r("Write at", dailyTimePicker),
                r("Prompt", dailyPromptScroll, wide: true),
                r("Prompt file", dailyPromptFileStack, "Overrides the text above when readable.", wide: true),
                r("Save digest to", dailyStack, "Once a day, the day's summaries roll up into a monthly "
                  + "folder (YYYY-MM/) under the folder you pick. Empty = alongside the summaries. "
                  + "A slept-through deadline catches up on wake.", wide: true),
                r("File name", dailyNameField, "Tokens: {date} → 2026-07-09, {month} → 2026-07. "
                  + "Empty uses \(dailyDigestNameDefault).", wide: true),
            ], group: "pp.summary"),
            Section(header: "Custom command", note: nil, rows: [
                r("Command", postProcessField, "Freeform: runs in a login shell with the transcript path "
                  + "appended as the last argument.", wide: true),
            ], group: "pp.shell"),
        ])
        // Each engine gets a switch; the overlay's picker lists only engines that are ON and READY.
        // An engine missing its key says so right here instead of failing later inside the caption area.
        func engineSwitch(_ e: LiveEngine) -> NSSwitch { engineSwitches.first { $0.engine == e }!.box }
        // In a vendor section the header already names the engine, so the row says what the switch does;
        // under "On-device" the row IS the engine's name, because two engines share that header.
        func engineRow(_ e: LiveEngine, _ desc: String, named: Bool = false) -> Row {
            sw(engineSwitch(e), named ? e.plainTitle : "Use for live captions",
               desc + (e.notReadyReason.map { " \($0)" } ?? ""))
        }
        pane("Live Captions", "captions.bubble", .systemTeal, [
            Section(header: nil, note: "Cloud caption engines stream audio off-device — only while the live "
                    + "overlay runs with that engine selected. Keys are stored in the Keychain, never in "
                    + "preferences or backups. Pick the engine in the overlay's control bar.", rows: []),
            Section(header: "On-device", note: nil, rows: [
                engineRow(.apple, "Apple's on-device recognizer — lowest latency, no network.", named: true),
                engineRow(.whisper, "whisper.cpp on the same model as the saved transcript — slower, more accurate.", named: true),
            ]),
            Section(header: "Deepgram", note: nil, rows: [
                engineRow(.deepgram, "Streaming cloud recognizer (model: nova-2)."),
                r("API key", deepgramKeyField, "Get a key at console.deepgram.com (model: nova-2).", wide: true),
            ], icon: vendorBadge("waveform", NSColor(srgbRed: 0.07, green: 0.80, blue: 0.55, alpha: 1))),
            Section(header: "OpenAI", note: nil, rows: [
                engineRow(.openai, "Realtime transcription over a websocket (gpt-4o-transcribe)."),
                r("API key", openaiKeyField, "platform.openai.com — or a key your gateway accepts (gpt-4o-transcribe).", wide: true),
                r("Base URL", openaiBaseField, "OpenAI-compatible gateway / corporate proxy. Leave empty for api.openai.com.", wide: true),
            ], icon: vendorBadge("sparkles", NSColor(srgbRed: 0.06, green: 0.64, blue: 0.50, alpha: 1))),
            Section(header: "Gladia", note: nil, rows: [
                engineRow(.gladia, "Streaming cloud recognizer with broad language coverage."),
                r("API key", gladiaKeyField, "app.gladia.io — broad language coverage incl. Korean streaming.", wide: true),
            ], icon: vendorBadge("globe", NSColor(srgbRed: 0.42, green: 0.31, blue: 0.95, alpha: 1))),
        ])
        pane("General", "gearshape", .systemGray, [
            Section(header: "General", note: nil, rows: [
                sw(loginBtn, "Start at login", "Launch macrec on login for around-the-clock recording."),
                sw(updateBtn, "Check for updates daily", "Silently checks GitHub once a day and notifies only "
                  + "when a new release is out. Check now from the tray menu → Check for Updates…"),
            ]),
        ])

        // Save applies in place and leaves Settings open, so it must announce itself: the footer flashes.
        let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveSettings)); saveBtn.keyEquivalent = "\r"
        let closeBtn = NSButton(title: "Close", target: self, action: #selector(closeOnly)); closeBtn.keyEquivalent = "\u{1b}"
        savedLabel.font = .systemFont(ofSize: 12)
        savedLabel.textColor = .secondaryLabelColor
        savedLabel.isHidden = true
        let btns = NSStackView(views: [savedLabel, closeBtn, saveBtn]); btns.orientation = .horizontal; btns.spacing = 10
        btns.translatesAutoresizingMaskIntoConstraints = false
        footerButtonsForTest = [closeBtn, saveBtn]

        // ── vertical navigation: search + source list on the left, one pane on the right ──
        sidebarSearch.placeholderString = "Search"
        sidebarSearch.target = self
        sidebarSearch.action = #selector(searchChanged)
        sidebarSearch.sendsSearchStringImmediately = true
        sidebarSearch.translatesAutoresizingMaskIntoConstraints = false

        sidebarList.style = .sourceList
        sidebarList.headerView = nil
        sidebarList.rowHeight = 34   // more breathing room between rows (was cramped)
        sidebarList.focusRingType = .none
        // Source-list metrics (inset rows, type-select). The selection PILL itself is drawn by
        // SidebarRowView.drawSelection — the stock source-list drawing dims whenever the table isn't
        // first responder, which is what made the selection appear to blink blue.
        sidebarList.selectionHighlightStyle = .sourceList
        sidebarList.addTableColumn(NSTableColumn(identifier: .init("pane")))
        sidebarList.dataSource = self
        sidebarList.delegate = self
        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebarList
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarSearch); sidebar.addSubview(sidebarScroll)

        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        // General leads (identity/behavior first), then the recording pipeline in flow order.
        // Pipeline order: identity → capture → when → where → text → title → summary → live mode.
        let paneOrder = ["General", "Recording", "Schedule", "Storage", "Transcription", "Titling", "Summaries", "Live Captions"]
        panesForTest.sort { (paneOrder.firstIndex(of: $0.title) ?? 99) < (paneOrder.firstIndex(of: $1.title) ?? 99) }
        visiblePaneIndexes = Array(panesForTest.indices)
        sidebarList.reloadData()

        let sep = NSBox(); sep.boxType = .separator; sep.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(sidebar); content.addSubview(paneContainer); content.addSubview(sep); content.addSubview(btns)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 200),
            sidebarSearch.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 12),
            sidebarSearch.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            sidebarSearch.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            sidebarScroll.topAnchor.constraint(equalTo: sidebarSearch.bottomAnchor, constant: 8),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            paneContainer.topAnchor.constraint(equalTo: content.topAnchor),
            paneContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            paneContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            paneContainer.bottomAnchor.constraint(equalTo: sep.topAnchor),
            sep.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sep.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: btns.topAnchor, constant: -10),
            btns.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            btns.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        window?.contentView = content
        selectPane(0)
        sidebarList.selectRowIndexes([0], byExtendingSelection: false)
    }

    /// Swap the visible pane. The container hosts exactly one pane at a time (same views the old
    /// tabs held — load()/save() field wiring is untouched). The window is a FIXED size; a pane taller
    /// than it scrolls (user ask: default scroll, permanent scrollbar — no auto-resizing window).
    private func selectPane(_ index: Int) {
        guard panesForTest.indices.contains(index) else { return }
        selectedPane = index
        paneContainer.subviews.forEach { $0.removeFromSuperview() }
        let v = panesForTest[index].view
        v.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: paneContainer.topAnchor),
            v.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor),
        ])
    }

    /// Count PassthroughScrollViews across every built pane — proves the nested-scroll fix is wired
    /// into the real view tree (prompt, daily-prompt, calendar), not just the declared field types.
    var passthroughScrollCountForTest: Int {
        func count(_ v: NSView) -> Int {
            (v is PassthroughScrollView ? 1 : 0) + v.subviews.reduce(0) { $0 + count($1) }
        }
        return panesForTest.reduce(0) { $0 + count($1.view) }
    }

    /// Test hooks for the Summaries Mode tab: set the mode and read back whether a section group is
    /// fully shown (all its views visible). Lets selftest prove the tab swaps sections, not greys them.
    fileprivate func setPPModeForTest(_ raw: String) {
        ppModeSeg.selectedSegment = ppModeValues.firstIndex(of: raw) ?? 0
        updatePostProcessEnabled()
    }
    fileprivate func ppGroupVisibleForTest(_ g: String) -> Bool {
        let vs = sectionGroupViews[g] ?? []
        return !vs.isEmpty && vs.allSatisfy { !$0.isHidden }
    }

    /// The scroll document inside a pane view (its fitting height drives the snapshot capture size).
    private func paneDoc(in v: NSView) -> NSView? {
        if let sv = v as? NSScrollView { return sv.documentView }
        for s in v.subviews { if let d = paneDoc(in: s) { return d } }
        return nil
    }

    /// UI TEST KIT (see `macrec settings-snapshot`): render every pane to a PNG so a human — or the
    /// next build — can actually LOOK at the Settings window instead of trusting structural checks.
    /// Returns the files written. This exists because a "structurally valid" pane (grids present)
    /// shipped visually broken twice; snapshots make the breakage impossible to miss.
    func snapshotAllPanes(to dir: URL) -> [URL] {
        load()
        guard let win = window, let content = win.contentView else { return [] }
        let appearance = win.effectiveAppearance   // render in the user's real (likely dark) appearance
        var written: [URL] = []
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        win.setContentSize(NSSize(width: 880, height: 600))   // the real, fixed runtime size (faithful)
        for i in panesForTest.indices {
            sidebarList.selectRowIndexes([i], byExtendingSelection: false)   // drives selectPane via delegate
            selectPane(i)
            content.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            let bounds = content.bounds
            guard bounds.width > 1, bounds.height > 1 else { continue }
            // Composite the whole hierarchy over the window background, in the real appearance:
            // fill windowBackgroundColor, then draw the view tree. This matches what the user
            // sees (white labels on a dark pane) — an offscreen PDF alone dropped the background
            // and made dark-mode labels vanish on a white page.
            let img = NSImage(size: bounds.size)
            img.lockFocus()
            appearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                NSRect(origin: .zero, size: bounds.size).fill()
                if let ctx = NSGraphicsContext.current {
                    content.displayIgnoringOpacity(bounds, in: ctx)
                }
            }
            img.unlockFocus()
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let safe = panesForTest[i].title.replacingOccurrences(of: "/", with: "-")
            let url = dir.appendingPathComponent(String(format: "pane-%d-%@.png", i, safe))
            try? png.write(to: url)
            written.append(url)
        }
        return written
    }

    /// AUTOMATED UI REGRESSION TEST (runs in selftest / CI, headless). Lays out every pane at a
    /// real window size and returns human-readable layout defects: any control collapsed to ~zero
    /// size, or two controls overlapping. The NSBox "card" redesign floated its grids so controls
    /// overlapped — this assertion fails the build on exactly that class of breakage, so a broken
    /// Settings window can never ship "green" again.
    func paneLayoutIssues() -> [String] {
        guard let win = window, let content = win.contentView else { return ["settings: no window"] }
        win.setContentSize(NSSize(width: 880, height: 640))
        var issues: [String] = []
        for i in panesForTest.indices {
            selectPane(i)
            content.layoutSubtreeIfNeeded()
            let paneView = panesForTest[i].view
            let title = panesForTest[i].title
            var rects: [(String, NSRect)] = []
            func walk(_ v: NSView) {
                if v.isHidden { return }         // hidden tab sections (Summaries Mode) aren't laid out — skip
                if v is NSScroller { return }   // overlay scrollbars are chrome (0-wide when hidden, sit over content)
                if v is NSControl || v is NSTextView {
                    let f = v.frame
                    if f.width < 4 || f.height < 4 {
                        issues.append("\(title): \(type(of: v)) collapsed to \(Int(f.width))×\(Int(f.height))")
                    }
                    // NSTextView lives inside a scroll clip: its content frame is taller than the
                    // visible clip, so its "overlap" with the next row is expected, not a bug —
                    // record it for the zero-size check but not for overlap.
                    if !(v is NSTextView) { rects.append(("\(type(of: v))", v.convert(v.bounds, to: paneView))) }
                }
                if v is NSTextView { return }   // don't descend into a text view's internals
                for s in v.subviews { walk(s) }
            }
            walk(paneView)
            for a in 0..<rects.count {
                for b in (a + 1)..<rects.count {
                    let o = rects[a].1.intersection(rects[b].1)
                    if o.width > 6, o.height > 6 {
                        issues.append("\(title): \(rects[a].0) overlaps \(rects[b].0) by \(Int(o.width))×\(Int(o.height))")
                    }
                }
            }
        }
        return issues
    }

    @objc private func searchChanged() {
        visiblePaneIndexes = settingsSearchHits(query: sidebarSearch.stringValue,
                                                index: panesForTest.map { $0.searchText })
        sidebarList.reloadData()
        // Auto-select the best hit so typing alone lands on the right pane.
        if let first = visiblePaneIndexes.first {
            sidebarList.selectRowIndexes([0], byExtendingSelection: false)
            if selectedPane != first { selectPane(first) }
        }
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

    /// Only the fields the selected mode actually uses are editable — the form reads as one choice.
    @objc private func ppModeChanged() { updatePostProcessEnabled() }
    /// Mode acts as a TAB: it SHOWS only the selected mode's settings (Automatic summary + Daily digest,
    /// or Custom command) and hides the rest — instead of greying everything out, which read as a
    /// half-built form. Off shows a one-line note.
    private func updatePostProcessEnabled() {
        let mode = PostProcessMode(rawValue: ppModeValues[max(0, ppModeSeg.selectedSegment)]) ?? .off
        setSectionGroup("pp.summary", visible: mode == .summary)
        setSectionGroup("pp.shell", visible: mode == .shell)
        setSectionGroup("pp.off", visible: mode == .off)
        promptView.isEditable = true   // shown only in summary mode now, always editable there
    }

    /// Show or hide a tagged section group (header + note + card), then relay out. The pane scrolls if
    /// the visible content overflows.
    private func setSectionGroup(_ group: String, visible: Bool) {
        for v in sectionGroupViews[group] ?? [] { v.isHidden = !visible }
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    @objc private func addApp() {
        let i = addAppPopup.indexOfSelectedItem
        guard i > 0, i < runningAppIds.count else { return }
        let bid = runningAppIds[i]
        var cur = (excludeTokens.objectValue as? [String]) ?? []
        if !cur.contains(bid) { cur.append(bid); excludeTokens.objectValue = cur }
        addAppPopup.selectItem(at: 0)
    }

    // ── Schedule pickers: select days & time ranges instead of typing them ──

    /// The "Hours" control: the range rows + an "Add time range" button beneath them.
    private func buildHoursControl() -> NSView {
        let add = NSButton(title: "  Add time range", target: self, action: #selector(addHourRange))
        add.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: "Add")
        add.imagePosition = .imageLeading
        add.bezelStyle = .inline
        add.controlSize = .small
        let v = NSStackView(views: [hoursRangesStack, add])
        v.orientation = .vertical; v.alignment = .leading; v.spacing = 8
        v.translatesAutoresizingMaskIntoConstraints = false
        hoursControlView = v
        return v
    }

    /// Days & Hours only apply when "Record only on a schedule" is ON — dim/disable them otherwise
    /// so the pane never looks like it's asking for input it will ignore.
    @objc private func scheduleToggled() { updateScheduleEnabled() }
    private func updateScheduleEnabled() {
        let on = schedBtn.state == .on
        daysSeg.isEnabled = on
        func setEnabled(_ v: NSView) {
            if let c = v as? NSControl { c.isEnabled = on }
            v.subviews.forEach(setEnabled)
        }
        if let h = hoursControlView { setEnabled(h) }
    }

    /// One time-range row: start–end pickers + a remove button. Minutes-since-midnight in, so load()
    /// can seed it and the reference date is irrelevant (only hour:minute is read back).
    private func makeHourRow(startMins: Int, endMins: Int) -> NSStackView {
        func picker(_ mins: Int) -> NSDatePicker {
            let p = NSDatePicker()
            p.datePickerStyle = .textFieldAndStepper
            p.datePickerElements = .hourMinute
            p.translatesAutoresizingMaskIntoConstraints = false
            var comps = DateComponents(); comps.year = 2000; comps.month = 1; comps.day = 1
            comps.hour = min(23, mins / 60); comps.minute = mins % 60
            p.dateValue = Calendar.current.date(from: comps) ?? p.dateValue
            return p
        }
        let dash = NSTextField(labelWithString: "–"); dash.textColor = .secondaryLabelColor
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove") ?? NSImage(),
                              target: self, action: #selector(removeHourRange(_:)))
        remove.isBordered = false
        remove.contentTintColor = .secondaryLabelColor
        let row = NSStackView(views: [picker(startMins), dash, picker(endMins), remove])
        row.orientation = .horizontal; row.spacing = 6; row.alignment = .centerY
        return row
    }

    @objc private func addHourRange() {
        hoursRangesStack.addArrangedSubview(makeHourRow(startMins: 9 * 60, endMins: 18 * 60))
        refitAfterScheduleChange()
    }

    @objc private func removeHourRange(_ sender: NSButton) {
        guard let row = sender.superview as? NSStackView else { return }
        hoursRangesStack.removeArrangedSubview(row); row.removeFromSuperview()
        refitAfterScheduleChange()
    }

    /// The Hours list grew/shrank — relay out (the pane scrolls if it now overflows).
    private func refitAfterScheduleChange() {
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// Read the day multi-select back into the parser's comma format ("mon,wed,fri"). Empty = every day.
    fileprivate func serializeDays() -> String {
        daySegKeys.enumerated().filter { daysSeg.isSelected(forSegment: $0.offset) }
            .map { $0.element }.joined(separator: ",")
    }

    /// Read the time-range rows back into "HH:MM-HH:MM, …". Empty list = all hours.
    fileprivate func serializeHours() -> String {
        hoursRangesStack.arrangedSubviews.compactMap { row -> String? in
            let ps = row.subviews.compactMap { $0 as? NSDatePicker }
            guard ps.count == 2 else { return nil }
            func hhmm(_ p: NSDatePicker) -> String {
                let c = Calendar.current.dateComponents([.hour, .minute], from: p.dateValue)
                return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            }
            return "\(hhmm(ps[0]))-\(hhmm(ps[1]))"
        }.joined(separator: ", ")
    }

    /// Seed the pickers from the saved pref strings (parsed via the same RecordSchedule logic the
    /// engine uses, so what you see is exactly what will record).
    fileprivate func loadScheduleUI(days: String, hours: String) {
        let wd = RecordSchedule.parseDays(days)                     // 1=Sun … 7=Sat
        let keyNum = ["mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7, "sun": 1]
        for (i, k) in daySegKeys.enumerated() { daysSeg.setSelected(wd.contains(keyNum[k] ?? 0), forSegment: i) }
        hoursRangesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for r in RecordSchedule.parseRanges(hours) {
            hoursRangesStack.addArrangedSubview(makeHourRow(startMins: r.start, endMins: min(r.end, 1439)))
        }
    }

    /// Fill the "add a calendar" popup with the user's event calendars (by title). Picking one
    /// appends it to the token field; an empty token field means "use all calendars".
    /// A scrollable checkbox list of the user's event calendars (none checked = all). Keeps every
    /// calendar visible even with many entries or long names.
    /// "● Calendar name" — the calendar's own color as a leading dot, the way Calendar.app shows it.
    /// The plain `name` is what gets persisted; this only changes how the row reads.
    private func calendarCheckboxTitle(name: String, color: NSColor, font: NSFont) -> NSAttributedString {
        let side: CGFloat = 9
        let dot = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            color.setFill(); NSBezierPath(ovalIn: r).fill(); return true
        }
        let att = NSTextAttachment()
        att.image = dot
        att.bounds = NSRect(x: 0, y: (font.capHeight - side) / 2, width: side, height: side)
        let s = NSMutableAttributedString(attachment: att)
        s.append(NSAttributedString(string: "  \(name)",
                                    attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        return s
    }

    private func buildCalendarList() -> NSView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        calChecks = []
        let cals = CalendarLookup.availableCalendars()
        if cals.isEmpty {
            let l = NSTextField(labelWithString: "No calendars available (grant Calendar access, then reopen).")
            l.textColor = .secondaryLabelColor; l.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(l)
        }
        for (name, color) in cals {
            let box = NSButton(checkboxWithTitle: name, target: nil, action: nil)
            box.attributedTitle = calendarCheckboxTitle(name: name, color: color, font: box.font ?? .systemFont(ofSize: 13))
            box.setAccessibilityLabel(name)   // the attributed title leads with an image attachment
            stack.addArrangedSubview(box); calChecks.append((name, box))
        }
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        let scroll = PassthroughScrollView()   // wheel passes to the pane when the list fits
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay        // overlay + autohide: no scrollbar unless the list overflows (user)
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder   // borderless: the card is the container — no box-inside-a-box
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        // Grow to fit all calendars up to a cap, then scroll (instead of a fixed short box).
        let naturalH = CGFloat(max(1, cals.count)) * 22 + 4
        scroll.heightAnchor.constraint(equalToConstant: min(naturalH, 220)).isActive = true
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        ])
        return scroll
    }

    private func idx<T: Equatable>(_ v: T, _ arr: [T]) -> Int { arr.firstIndex(of: v) ?? 0 }

    /// The controller instance is cached by the app — RELOAD the fields from prefs on every open,
    /// or edits abandoned with Cancel linger in the form and a later Save silently persists them
    /// (confirmed review finding).
    override func showWindow(_ sender: Any?) {
        load()
        super.showWindow(sender)
    }

    private func load() {
        let c = EngineConfig.load()
        segPopup.selectItem(at: idx(Int(c.segmentSeconds), segValues))
        langPopup.selectItem(at: idx(c.whisperLang, langValues))
        transcriptLangPopup.selectItem(at: idx(TranscriptL10n.configuredCode, tLangValues))   // explicit save (even "") beats env
        modelPopup.selectItem(at: idx(Pref.str(Pref.model, "MR_WHISPER_MODEL", WhisperCatalog.defaultName), modelNames))
        customModelField.stringValue = Pref.str(Pref.customModel, "MR_MODEL_URL", "")
        // Presence, not the secret. Prefilling the real key made opening Settings an authorization prompt
        // per engine, for a value the user never asked to see.
        for (account, field) in [("deepgram", deepgramKeyField), ("openai", openaiKeyField), ("gladia", gladiaKeyField)] {
            field.stringValue = Keychain.exists(account) ? Self.keyMask : ""
        }
        openaiBaseField.stringValue = OpenAILiveTranscriber.configuredBase   // explicit save (even "") beats env
        postProcessField.stringValue = Pref.postProcessCommand               // same explicit-save semantics
        // Show the EFFECTIVE mode (incl. the v1 migration: unset mode + v1 command = Custom command) —
        // displaying Off while a hook is live would let Save silently kill it.
        ppModeSeg.selectedSegment = idx(effectivePostProcessMode(
            rawMode: Pref.explicit(Pref.postProcessMode, "MR_POST_PROCESS_MODE"),
            shellCmd: Pref.postProcessCommand).rawValue, ppModeValues)
        runnerPopup.selectItem(at: idx(Pref.explicit(Pref.summaryRunner, "MR_SUMMARY_RUNNER"), runnerValues))
        let savedPrompt = Pref.explicit(Pref.summaryPrompt, "MR_SUMMARY_PROMPT")
        promptView.string = savedPrompt.isEmpty ? defaultSummaryPrompt : savedPrompt   // show the editable default
        promptFileField.stringValue = Pref.explicit(Pref.summaryPromptFile, "MR_SUMMARY_PROMPT_FILE")
        summaryOutField.stringValue = Pref.explicit(Pref.summaryOut, "MR_SUMMARY_OUT")
        dailyBtn.state = Pref.bool(Pref.dailyDigest, "MR_DAILY_DIGEST", false) ? .on : .off
        updateBtn.state = Pref.bool(Pref.autoUpdateCheck, "MR_AUTO_UPDATE_CHECK", true) ? .on : .off
        let savedDaily = Pref.explicit(Pref.dailyPrompt, "MR_DAILY_DIGEST_PROMPT")
        dailyPromptView.string = savedDaily.isEmpty ? defaultDailyDigestPrompt : savedDaily
        dailyPromptFileField.stringValue = Pref.explicit(Pref.dailyPromptFile, "MR_DAILY_DIGEST_PROMPT_FILE")
        dailyOutField.stringValue = Pref.explicit(Pref.dailyDigestOut, "MR_DAILY_DIGEST_OUT")
        dailyNameField.stringValue = Pref.explicit(Pref.dailyDigestName, "MR_DAILY_DIGEST_NAME")
        for (engine, box) in engineSwitches { box.state = engine.isEnabled ? .on : .off }
        let hm = Pref.str(Pref.dailyDigestTime, "MR_DAILY_DIGEST_TIME", "20:00").split(separator: ":").compactMap { Int($0) }
        var tc = DateComponents(); tc.hour = hm.count == 2 ? hm[0] : 20; tc.minute = hm.count == 2 ? hm[1] : 0
        dailyTimePicker.dateValue = Calendar.current.date(from: tc) ?? Date()
        hintsTermsField.stringValue = Pref.explicit(Pref.hintsTerms, "MR_HINTS")
        hintsFileField.stringValue = Pref.explicit(Pref.hintsFile, "MR_HINTS_FILE")
        hintsCalBtn.state = Pref.bool(Pref.hintsCalendar, "MR_HINTS_CALENDAR", false) ? .on : .off
        schedBtn.state = Pref.bool(Pref.schedEnabled, "MR_SCHEDULE", false) ? .on : .off
        loadScheduleUI(days: Pref.explicit(Pref.schedDays, "MR_SCHEDULE_DAYS"),
                       hours: Pref.explicit(Pref.schedHours, "MR_SCHEDULE_HOURS"))
        updateScheduleEnabled()   // dim Days/Hours when the schedule is off
        // Long paths head-truncate in the field — the tooltip always carries the full value.
        for f in [dirField, audioDirField, customModelField, hintsFileField, promptFileField,
                  summaryOutField, postProcessField] {
            f.toolTip = f.stringValue.isEmpty ? nil : f.stringValue
        }
        updatePostProcessEnabled()
        voiceField.stringValue = String(Int(c.voiceMinSeconds))
        vadBtn.state = c.vadEnabled ? .on : .off
        systemAudioBtn.state = Pref.bool(Pref.systemAudio, "MR_SYSTEM_AUDIO", true) ? .on : .off
        echoBtn.state = Pref.bool(Pref.echoReduce, "MR_ECHO_REDUCE", false) ? .on : .off
        calBtn.state = c.useCalendarTitles ? .on : .off
        keepAudioBtn.state = c.keepAudio ? .on : .off
        audioRawCombo.stringValue = c.audioRawDays == 0 ? "Don't compress"
                                                        : AudioArchivePolicy.retentionTitle(c.audioRawDays)
        audioRetCombo.stringValue = AudioArchivePolicy.retentionTitle(c.audioRetentionDays)
        recolorRetentionCombos()
        txtRetPopup.selectItem(at: idx(c.transcriptRetentionDays, retValues))
        excludeTokens.objectValue = c.excludeBundleIds
        // Trim stored titles (older builds stored via a token field that could carry stray spaces).
        let selectedCals = Set((Pref.d.stringArray(forKey: Pref.calendars) ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) })
        for (name, box) in calChecks { box.state = selectedCals.contains(name) ? .on : .off }
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

    @objc private func chooseDir()        { choosePath(into: dirField, files: false) }
    @objc private func chooseAudioDir()   { choosePath(into: audioDirField, files: false) }
    @objc private func chooseSummaryDir() { choosePath(into: summaryOutField, files: false) }
    @objc private func chooseDailyDir()   { choosePath(into: dailyOutField, files: false) }
    // A prompt/hints file is picked in Finder like any other path.
    @objc private func choosePromptFile()      { choosePath(into: promptFileField, files: true) }
    @objc private func chooseDailyPromptFile() { choosePath(into: dailyPromptFileField, files: true) }
    @objc private func chooseHintsFile()       { choosePath(into: hintsFileField, files: true) }

    /// The one picker behind every "Choose…" button — a folder picker (`files: false`) or a file
    /// picker (`files: true`). macrec is a menu-bar (`.accessory`) app, so a bare
    /// `NSOpenPanel.runModal()` can open behind everything or never take key focus — the "Choose…"
    /// button then looked dead (user report: Storage "Choose…" did nothing). Presenting the panel as a
    /// SHEET on the Settings window makes it always surface and stay tied to the window; we fall back
    /// to activate-then-runModal only if the window is somehow absent. Seeds at the field's current path.
    private func choosePath(into field: NSTextField, files: Bool) {
        let p = NSOpenPanel()
        p.canChooseDirectories = !files
        p.canChooseFiles = files
        p.allowsMultipleSelection = false
        p.canCreateDirectories = !files
        let cur = (field.stringValue as NSString).expandingTildeInPath
        if !field.stringValue.isEmpty {
            // A file field seeds the panel at its enclosing DIRECTORY, with the current file's name in
            // the name field so it's selected rather than hunted for; handing NSOpenPanel a file path as
            // `directoryURL` opens the user's home instead.
            p.directoryURL = files ? URL(fileURLWithPath: cur).deletingLastPathComponent()
                                   : URL(fileURLWithPath: cur)
            if files { p.nameFieldStringValue = URL(fileURLWithPath: cur).lastPathComponent }
        }
        let apply: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let u = p.url else { return }
            field.stringValue = u.path
            field.toolTip = u.path   // fields head-truncate; the tooltip must track the new value (load() sets it once)
        }
        // Present as a sheet on a VISIBLE window; only fall back to runModal when there's none to host
        // one (headless selftest/snapshot) — a bare runModal on this .accessory app opens behind.
        if dirPickerPresentation(hasVisibleWindow: window?.isVisible == true) == .sheet, let win = window {
            p.beginSheetModal(for: win, completionHandler: apply)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            apply(p.runModal())
        }
    }

    /// Every "Choose…" button in the built panes (folder AND file pickers) is bound to a handler this
    /// controller actually implements — a headless guard against a picker button silently wired to
    /// nothing / a renamed selector. NOTE: this does NOT prove the panel surfaces (the real bug) — the
    /// sheet-vs-runModal decision is tested via dirPickerPresentation, and actual surfacing by
    /// manually driving Settings.
    /// Switches whose name lives in a sibling label and who therefore announce nothing to VoiceOver.
    /// Replacing the old `NSButton(checkboxWithTitle:)` rows silently dropped every label.
    var unlabeledSwitchesForTest: Int {
        var n = 0
        func walk(_ v: NSView) {
            if v is NSSwitch, v.accessibilityLabel()?.isEmpty ?? true { n += 1 }
            v.subviews.forEach(walk)
        }
        for p in panesForTest { walk(p.view) }
        return n
    }

    var chooseButtonsWiredForTest: (count: Int, allWired: Bool) {
        var btns: [NSButton] = []
        func walk(_ v: NSView) { if let b = v as? NSButton, b.title == "Choose…" { btns.append(b) }; v.subviews.forEach(walk) }
        for p in panesForTest { walk(p.view) }
        let allWired = btns.allSatisfy { b in
            guard let action = b.action, let target = b.target as? NSObject else { return false }
            return target.responds(to: action)
        }
        return (btns.count, allWired)
    }

    /// Visible confirmation that a Save landed, now that Save no longer closes the window. Re-saving
    /// restarts the fade rather than letting the first timer hide the label mid-flash.
    /// `cancel()` can't reach a fade that already started, so a generation counter fences its completion.
    private func flashSaved() {
        savedFlash?.cancel()
        flashGen &+= 1
        let gen = flashGen
        savedLabel.isHidden = false
        savedLabel.alphaValue = 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.flashGen else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; self.savedLabel.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in
                guard let self, gen == self.flashGen else { return }
                self.savedLabel.isHidden = true
            })
        }
        savedFlash = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    /// Shown in a key field when a credential is stored. Never a real key, and never saved back.
    static let keyMask = "••••••••••••"

    func loadForTest() { load() }
    var keyFieldsForTest: [String] { [deepgramKeyField, openaiKeyField, gladiaKeyField].map(\.stringValue) }

    /// Every pref the recorder reads. Missing one means Save saves it and nothing happens.
    private static let engineKeys = [
        Pref.segment, Pref.lang, Pref.transcriptLang, Pref.model, Pref.customModel, Pref.exclude,
        Pref.txtDir, Pref.audioDir, Pref.keepAudio, Pref.vad, Pref.systemAudio, Pref.echoReduce,
        Pref.cal, Pref.calendars, Pref.voiceMin, Pref.hintsTerms, Pref.hintsFile, Pref.hintsCalendar,
        Pref.audioRawDays, Pref.audioRetention, Pref.txtRetention,
        // The schedule belongs here: `restartEngine()` is what clears `schedulePaused` and re-baselines
        // the schedule, so leaving these out meant switching "Record only on a schedule" OFF saved the
        // pref and left the engine parked off-hours, with no way to get recording back from Settings.
        Pref.schedEnabled, Pref.schedDays, Pref.schedHours,
    ]
    /// A switch turned on for an engine with no key silently did nothing: the engine just never appeared
    /// in the overlay's picker. Say so at the moment the user saves it.
    private func warnAboutEnginesMissingCredentials() {
        let missing = enginesMissingCredentials(LiveEngine.allCases, enabled: { $0.isEnabled }, ready: { $0.isReady })
        guard !missing.isEmpty else { return }
        let names = missing.map(\.plainTitle).joined(separator: ", ")
        let a = NSAlert()
        a.messageText = missing.count == 1 ? "\(names) has no API key" : "Some engines have no API key"
        a.informativeText = "\(names) stayed switched on but won't appear in the overlay's engine picker "
            + "until the key is filled in. Everything else was saved."
        a.alertStyle = .warning
        if dirPickerPresentation(hasVisibleWindow: window?.isVisible == true) == .sheet, let win = window {
            a.beginSheetModal(for: win, completionHandler: nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    static var engineKeysForTest: [String] { engineKeys }
    private func engineSettingsDigest() -> String {
        engineFingerprint(Dictionary(uniqueKeysWithValues: Self.engineKeys.map {
            ($0, Pref.d.object(forKey: $0).map { String(describing: $0) } ?? "∅")
        }))
    }

    @objc private func saveSettings() {
        let engineBefore = engineSettingsDigest()
        // Keychain first — if a credential write fails, abort BEFORE touching any other setting so
        // the user isn't left with a half-saved state (and no key is silently lost). All-or-nothing:
        // keys saved earlier in the loop are rolled back (best effort) on a later failure.
        // Only credentials the user actually edited are touched. A field still showing the mask means
        // "unchanged", so Save never reads or rewrites a key it wasn't given — and never asks the user
        // to authorize handing the old one back just to save an unrelated setting.
        let creds = [("deepgram", deepgramKeyField, "Deepgram"), ("openai", openaiKeyField, "OpenAI"),
                     ("gladia", gladiaKeyField, "Gladia")]
            .filter { $0.1.stringValue != Self.keyMask }
        let previousKeys = creds.map { ($0.0, Keychain.get($0.0) ?? "") }
        for (i, cred) in creds.enumerated() {
            let (account, field, name) = cred
            if Keychain.set(account, field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) { continue }
            for (acct, old) in previousKeys[..<i] { Keychain.set(acct, old) }   // best-effort rollback
            let a = NSAlert()
            a.messageText = "Couldn't save the \(name) API key"
            a.informativeText = "The Keychain write failed (see the log). Settings were not applied — try saving again."
            a.alertStyle = .warning
            a.runModal()
            return   // keep Settings open
        }
        let d = Pref.d
        d.set(Double(segValues[max(0, segPopup.indexOfSelectedItem)]), forKey: Pref.segment)
        d.set(langValues[max(0, langPopup.indexOfSelectedItem)], forKey: Pref.lang)
        d.set(tLangValues[max(0, transcriptLangPopup.indexOfSelectedItem)], forKey: Pref.transcriptLang)
        d.set(modelNames[max(0, modelPopup.indexOfSelectedItem)], forKey: Pref.model)
        d.set(customModelField.stringValue.trimmingCharacters(in: .whitespaces), forKey: Pref.customModel)
        d.set(openaiBaseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.openaiBase)
        d.set(postProcessField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.postProcessCmd)
        d.set(ppModeValues[max(0, ppModeSeg.selectedSegment)], forKey: Pref.postProcessMode)
        d.set(runnerValues[max(0, runnerPopup.indexOfSelectedItem)], forKey: Pref.summaryRunner)
        d.set(promptView.string.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.summaryPrompt)
        d.set(promptFileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.summaryPromptFile)
        d.set(summaryOutField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.summaryOut)
        d.set(dailyBtn.state == .on, forKey: Pref.dailyDigest)
        d.set(updateBtn.state == .on, forKey: Pref.autoUpdateCheck)
        let dp = dailyPromptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        d.set(dp == defaultDailyDigestPrompt ? "" : dp, forKey: Pref.dailyPrompt)   // default stays editable, not stored
        d.set(dailyPromptFileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.dailyPromptFile)
        d.set(dailyOutField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.dailyDigestOut)
        d.set(dailyNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.dailyDigestName)
        // Persist the ON list: a cloud engine we add later must not become enabled behind the user's back.
        d.set(engineSwitches.filter { $0.box.state == .on }.map { $0.engine.rawValue }, forKey: Pref.liveEnginesOn)
        let tc = Calendar.current.dateComponents([.hour, .minute], from: dailyTimePicker.dateValue)
        d.set(String(format: "%02d:%02d", tc.hour ?? 20, tc.minute ?? 0), forKey: Pref.dailyDigestTime)
        d.set(hintsTermsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.hintsTerms)
        d.set(hintsFileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.hintsFile)
        d.set(hintsCalBtn.state == .on, forKey: Pref.hintsCalendar)
        d.set(schedBtn.state == .on, forKey: Pref.schedEnabled)
        d.set(serializeDays(), forKey: Pref.schedDays)
        d.set(serializeHours(), forKey: Pref.schedHours)
        d.set(Double(Int(voiceField.stringValue) ?? 5), forKey: Pref.voiceMin)
        d.set(vadBtn.state == .on, forKey: Pref.vad)
        d.set(systemAudioBtn.state == .on, forKey: Pref.systemAudio)
        d.set(echoBtn.state == .on, forKey: Pref.echoReduce)
        d.set(calBtn.state == .on, forKey: Pref.cal)
        d.set(keepAudioBtn.state == .on, forKey: Pref.keepAudio)
        // Unparseable combo text (shown red) keeps the previously saved period instead of guessing.
        if let v = AudioArchivePolicy.parseRetentionDays(audioRawCombo.stringValue) { d.set(v, forKey: Pref.audioRawDays) }
        if let v = AudioArchivePolicy.parseRetentionDays(audioRetCombo.stringValue) { d.set(v, forKey: Pref.audioRetention) }
        d.set(retValues[max(0, txtRetPopup.indexOfSelectedItem)], forKey: Pref.txtRetention)
        let ids = (excludeTokens.objectValue as? [String]) ?? []
        d.set(ids.joined(separator: " "), forKey: Pref.exclude)
        // Only persist if we actually listed calendars — otherwise (no Calendar access → empty list)
        // we'd silently wipe a previously-saved selection.
        if !calChecks.isEmpty {
            d.set(calChecks.filter { $0.box.state == .on }.map { $0.name }, forKey: Pref.calendars)
        }
        d.set(dirField.stringValue, forKey: Pref.txtDir)
        d.set(audioDirField.stringValue, forKey: Pref.audioDir)
        // Apply "Start at login" (skip on the dev machine where the LaunchAgent owns autostart).
        if #available(macOS 13, *), !LoginItem.managedByLaunchAgent {
            if LoginItem.setEnabled(loginBtn.state == .on) == .requiresApproval { LoginItem.openSettings() }
        }
        if #available(macOS 26, *) { LiveCaptions.shared.settingsSaved() }
        warnAboutEnginesMissingCredentials()
        // `stop()` discards the in-progress segment, and Return in any field now fires Save.
        if engineSettingsDigest() != engineBefore { onSave() }
        flashSaved()
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

// MARK: - live transcription (macOS 26 SpeechAnalyzer → real-time caption overlay)
//
// Tees the same canon (16 kHz mono) audio the recorder writes into an on-device SpeechAnalyzer per
// source (mic → "me", system → "them") for low-latency live captions in a floating panel. whisper-cli on
// segment rotation stays the authoritative, saved transcript — this overlay is an ephemeral view.

@available(macOS 26, *)
final class LiveTranscriber: LiveTranscribing {
    private let label: String
    private let locale: Locale
    private let onUpdate: (String, Bool) -> Void   // (text, isFinal)
    private let onLocale: ((Locale) -> Void)?      // reports the resolved speech locale once ready
    private let lock = NSLock()
    private var cont: AsyncStream<AnalyzerInput>.Continuation?
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var task: Task<Void, Never>?

    init(label: String, locale: Locale, onLocale: ((Locale) -> Void)? = nil,
         onUpdate: @escaping (String, Bool) -> Void) {
        self.label = label; self.locale = locale; self.onLocale = onLocale; self.onUpdate = onUpdate
    }

    func start() { task = Task { [weak self] in
        do { try await self?.run() } catch { elog("live[\(self?.label ?? "?")]: transcriber failed: \(error)") } } }

    private func run() async throws {
        // Locale.current can be a region SpeechTranscriber doesn't support (e.g. en_KR → error 15
        // "unsupported locale"). Map it to a supported (ideally already-installed) locale.
        let t0 = ProcessInfo.processInfo.systemUptime
        guard let (loc, isInstalled) = await Self.resolvedLocale(locale) else {
            elog("live[\(label)]: no supported speech locale for \(locale.identifier)"); return
        }
        if loc.identifier(.bcp47) != locale.identifier(.bcp47) {
            elog("live[\(label)]: locale \(locale.identifier) → \(loc.identifier(.bcp47))")
        }
        let transcriber = SpeechTranscriber(locale: loc, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        let t1 = ProcessInfo.processInfo.systemUptime
        // Only download/prepare when the locale isn't already installed — doing this on every start was
        // the main startup lag (seconds of dead air before the analyzer accepted audio).
        if !isInstalled, let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            elog("live[\(label)]: downloading speech model (\(loc.identifier(.bcp47)))…"); try await req.downloadAndInstall()
        }
        let t2 = ProcessInfo.processInfo.systemUptime
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, c) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        if Task.isCancelled { c.finish(); return }   // stopped mid-setup → EOF the input, don't publish
        // SpeechAnalyzer defers its model/ANE warm-up to the first audio buffer (~10s of dead air before
        // the first caption). Force it NOW, before exposing `cont`, so the warm-up runs during setup and
        // audio fed meanwhile is dropped (not queued) — the first real buffer then transcribes immediately.
        let tp = ProcessInfo.processInfo.systemUptime
        try await analyzer.prepareToAnalyze(in: fmt)
        if Task.isCancelled { c.finish(); return }   // stopped during warm-up → don't publish cont / clobber title
        lock.lock(); inputFormat = fmt; cont = c; lock.unlock()
        onLocale?(loc)   // now warm — surface the active language (replaces the "preparing" title)
        let t3 = ProcessInfo.processInfo.systemUptime
        elog(String(format: "live[%@]: analyzer ready (%@) — resolve %.1fs · assets %.1fs · start %.1fs · prepare %.1fs",
                    label, loc.identifier(.bcp47), t1 - t0, t2 - t1, tp - t2, t3 - tp))
        for try await result in transcriber.results {
            let text = String(result.text.characters)
            if !text.isEmpty { onUpdate(text, result.isFinal) }
        }
    }

    /// Map a requested locale to one SpeechTranscriber supports (exact → same-language same-region →
    /// same-language preferring en-US/GB → any same-language), preferring an already-installed one.
    private static func resolvedLocale(_ requested: Locale) async -> (locale: Locale, installed: Bool)? {
        let installed = await SpeechTranscriber.installedLocales
        if let hit = pickSpeechLocale(requested: requested, from: installed) { return (hit, true) }
        // Only query the (larger, slower) supported set when we don't already have it installed.
        let supported = await SpeechTranscriber.supportedLocales
        if let hit = pickSpeechLocale(requested: requested, from: supported) { return (hit, false) }
        return nil
    }

    /// Feed a captured PCM buffer (tap: 48 kHz stereo · mic: its native format) — convert to the
    /// analyzer's format and yield it. Called off the capture thread; the lock guards converter + cont.
    func feed(_ buf: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let cont else { return }   // analyzer not ready yet → drop
        guard let target = inputFormat else { cont.yield(AnalyzerInput(buffer: buf)); return }   // no negotiated format → pass through
        if buf.format == target { cont.yield(AnalyzerInput(buffer: buf)); return }
        if converter == nil || converter?.inputFormat != buf.format {
            converter = AVAudioConverter(from: buf.format, to: target)
        }
        guard let conv = converter else { return }
        let ratio = target.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false; var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        if err == nil, out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
    }

    func stop() {
        lock.lock(); cont?.finish(); cont = nil; lock.unlock()
        task?.cancel(); task = nil
    }
}

/// On-device translation of finalized caption lines (macOS 26 Translation framework). Best-effort:
/// if the language pair isn't installed/available it returns nil and captions show the original only.
@available(macOS 26, *)
final class LiveTranslator {
    private let session: TranslationSession
    private let lock = NSLock()
    private var prepared = false

    init(source: Locale.Language, target: Locale.Language) {
        session = TranslationSession(installedSource: source, target: target)
        // Pre-warm the pair now — the first translate can otherwise stall on the model download.
        Task { [weak self] in
            guard let self else { return }
            do { try await session.prepareTranslation(); lock.lock(); prepared = true; lock.unlock(); elog("live: translator ready") }
            catch { elog("live: translate prewarm failed: \(error)") }
        }
    }

    func translate(_ text: String) async -> String? {
        do {
            lock.lock(); let needPrep = !prepared; lock.unlock()
            if needPrep {                              // download/prepare the pair on first use
                try await session.prepareTranslation()
                lock.lock(); prepared = true; lock.unlock()   // only mark ready once prepare SUCCEEDS
            }
            return try await session.translate(text).targetText
        } catch { elog("live: translate failed: \(error)"); return nil }
    }
}

// MARK: - live transcription engines (pluggable)
//
// A live engine consumes fed PCM and calls back with caption text. Two implementations today —
// Apple SpeechAnalyzer (LiveTranscriber, low latency) and whisper.cpp (WhisperLiveTranscriber, higher
// accuracy esp. non-English). Add another — on-device (sherpa-onnx, Vosk) or a paid streaming CLOUD
// API (Deepgram, OpenAI realtime, …) for low-latency + high quality — by conforming to LiveTranscribing
// (feed audio, emit text) + a LiveEngine case; its API key/endpoint would come from Prefs in init.

/// One caption source's transcription engine. `feed` is called off the audio thread; `onUpdate(text,
/// isFinal)` reports a (possibly volatile) line; `onLocale` surfaces the active language for the UI.
protocol LiveTranscribing: AnyObject {
    func start()
    func feed(_ buffer: AVAudioPCMBuffer)
    func stop()
}

func envKeyPresent(_ name: String) -> Bool {
    !(ProcessInfo.processInfo.environment[name] ?? "").isEmpty
}

/// Selectable live engine. Extensible: add a case, a title, and a branch in `makeTranscriber`.
enum LiveEngine: String, CaseIterable {
    case apple, whisper, deepgram, openai, gladia
    /// The engine in use — but only if it is still selectable. A key deleted from the Keychain, or an
    /// engine switched off in Settings, must not leave the overlay pinned to an engine that can only
    /// print an error where the captions should be.
    static var current: LiveEngine {
        let stored = LiveEngine(rawValue: Pref.d.string(forKey: Pref.liveEngine) ?? "") ?? .apple
        return stored.isSelectable ? stored : .apple
    }
    var title: String {
        switch self {
        case .apple:    return "Apple"
        case .whisper:  return "Whisper"
        case .deepgram: return "Deepgram ☁"
        case .openai:   return "OpenAI ☁"
        case .gladia:   return "Gladia ☁"
        }
    }
    /// Can this engine actually run right now? A cloud engine needs its API key; whisper needs its
    /// binary and model. Offering one that can only answer "API key not set" is a promise the app
    /// cannot keep (AGENTS.md §2.8) — Deepgram sat in the picker with no credential for exactly that reason.
    var isReady: Bool {
        switch self {
        case .apple:    return true
        case .whisper:
            let c = EngineConfig.load()
            return FileManager.default.isExecutableFile(atPath: c.whisperCli)
                && FileManager.default.fileExists(atPath: c.whisperModel)
        // Presence, never the secret: reading a key is an authorization check the user has to answer.
        case .deepgram: return Keychain.exists("deepgram") || envKeyPresent("MR_DEEPGRAM_KEY")
        case .openai:   return Keychain.exists("openai") || envKeyPresent("MR_OPENAI_KEY")
        case .gladia:   return Keychain.exists("gladia") || envKeyPresent("MR_GLADIA_KEY")
        }
    }
    /// The title without the cloud marker — a row that already sits under a vendor header shouldn't
    /// repeat the glyph, and "Apple ☁" would be a lie.
    var plainTitle: String { title.replacingOccurrences(of: " ☁", with: "") }
    /// On-device engines are on out of the box; a CLOUD engine streams meeting audio off-device, so it
    /// stays off until the user turns it on deliberately. Opt-in, never opt-out, for anything that
    /// leaves the machine.
    var onByDefault: Bool { self == .apple || self == .whisper }
    /// The user's per-engine switch (Settings › Live Captions). No stored list yet = the defaults.
    var isEnabled: Bool {
        liveEngineEnabled(self, storedOn: Pref.d.stringArray(forKey: Pref.liveEnginesOn),
                          selectedEngine: Pref.d.string(forKey: Pref.liveEngine))
    }
    var isSelectable: Bool { isReady && isEnabled }
    /// Why an engine can't be offered — shown next to its switch so the setting isn't a mystery.
    var notReadyReason: String? {
        guard !isReady else { return nil }
        return self == .whisper ? "whisper-cli or its model isn't installed yet."
                                : "Add the API key below to use this engine."
    }
}

/// A stable digest of the settings the RECORDING engine consumes. Restarting the engine throws away
/// the in-progress segment (`RecordingEngine.stop()` deletes the trailing partial), so a Save that
/// changed nothing the engine cares about must not restart it. This matters far more now that Save
/// keeps the window open: Return in any text field triggers Save, and a segment can be up to 2 hours.
/// Pure over the values, so a selftest can prove which keys do and don't trigger a restart.
func engineFingerprint(_ values: [String: String]) -> String {
    values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "\u{1}")
}

/// Is this engine switched on? With no stored list (every install that predates the switches) the
/// defaults apply — PLUS whatever engine the user had already chosen. Cloud engines becoming opt-in
/// must not silently downgrade someone who was already running Deepgram to Apple behind their back.
/// Pure + selftested.
func liveEngineEnabled(_ e: LiveEngine, storedOn: [String]?, selectedEngine: String?) -> Bool {
    if let on = storedOn { return on.contains(e.rawValue) }
    return e.onByDefault || e.rawValue == selectedEngine
}

/// Engines the user switched on that cannot run for want of a credential. Pure + selftested.
func enginesMissingCredentials(_ engines: [LiveEngine], enabled: (LiveEngine) -> Bool,
                               ready: (LiveEngine) -> Bool) -> [LiveEngine] {
    engines.filter { enabled($0) && !ready($0) }
}

/// The engine a popup index refers to. It indexes the FILTERED list the popup was built from — reading
/// `LiveEngine.allCases[index]` selected the wrong engine the moment any engine was left out of the
/// menu. Pure + selftested.
func engineAtPopupIndex(_ index: Int, choices: [LiveEngine]) -> LiveEngine? {
    guard !choices.isEmpty else { return nil }
    return choices[min(max(0, index), choices.count - 1)]
}

/// The engines the overlay's picker may offer: switched on by the user AND actually runnable. Apple is
/// the floor — an empty picker would strand the user with no engine and no way back. Pure + selftested.
func selectableLiveEngines(_ all: [LiveEngine], ready: (LiveEngine) -> Bool,
                           enabled: (LiveEngine) -> Bool) -> [LiveEngine] {
    // `enabled` first: it is a plain pref read, while `ready` probes the Keychain and the filesystem.
    let picked = all.filter { enabled($0) && ready($0) }
    return picked.isEmpty ? [.apple] : picked
}

/// whisper.cpp live engine: accumulates fed audio into a 16 kHz mono segment, and every ~2 s re-runs
/// `whisper-cli` on the current segment for a volatile caption line. A lightweight energy gate finalizes
/// the line after ~1 s of silence (or a 12 s cap). Reuses the same whisper-cli + model as the saved
/// transcript. Not on the real-time path — runs on its own queue. Tunables are named constants below.
final class WhisperLiveTranscriber: LiveTranscribing {
    private let label: String
    private let locale: Locale
    private let lang: String                    // whisper -l code (e.g. "ko"; "auto" if unknown)
    private let onUpdate: (String, Bool) -> Void
    private let onLocale: ((Locale) -> Void)?
    private let cfg = EngineConfig.load()
    // Same proper-noun dictionary as the saved transcript; snapshotted on q at start() (the overlay
    // builds engines on the MAIN thread, and transcriptionHints does file IO + an EventKit query —
    // review finding: a slow hints file/calendar froze the whole app). q-confined thereafter.
    private var hints = ""
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("macrec-live-\(UUID().uuidString).wav")
    private let q = DispatchQueue(label: "macrec.whisperlive", qos: .userInitiated)
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var seg: [Float] = []               // current segment samples (16 kHz mono)
    private var startedAt = 0.0                 // systemUptime when the segment began
    private var lastVoiceAt = 0.0               // systemUptime of the last non-silent buffer
    private var timer: DispatchSourceTimer?
    private var running = false                 // a whisper-cli run is in flight
    private var proc: Process?                  // the in-flight whisper-cli, so stop() can terminate it

    // Tunables (kept named for future exposure as options).
    private let tick = 1.0, minDur = 0.6, silenceGap = 0.8, maxDur = 8.0, maxWindow = 30.0
    private let voiceRMS: Float = 0.006         // ~ -44 dBFS gate — permissive; only drops true silence
    private var voicedSamples = 0               // above-threshold samples in the current segment
    private let minVoicedSec = 0.2              // require this much real speech before running whisper

    init(label: String, locale: Locale, onLocale: ((Locale) -> Void)? = nil,
         onUpdate: @escaping (String, Bool) -> Void) {
        self.label = label; self.locale = locale; self.onLocale = onLocale; self.onUpdate = onUpdate
        self.lang = locale.language.languageCode?.identifier ?? "auto"
    }

    func start() {
        onLocale?(locale)   // whisper uses the requested language directly; surface it in the title
        q.async { [weak self] in   // hints do file IO + EventKit — off the main thread, before the first tick
            guard let self else { return }
            self.hints = transcriptionHints(start: Date(), end: Date())
        }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + tick, repeating: tick)
        t.setEventHandler { [weak self] in self?.transcribeIfReady() }
        t.resume(); timer = t
        elog("whisperlive[\(label)]: started (lang=\(lang), model=\((cfg.whisperModel as NSString).lastPathComponent))")
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let conv = to16kMono(buffer), let ch = conv.floatChannelData?[0] else { return }
        let n = Int(conv.frameLength); guard n > 0 else { return }
        var sum: Float = 0; for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = (sum / Float(n)).squareRoot()
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if seg.isEmpty { startedAt = now; voicedSamples = 0 }
        seg.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
        if rms > voiceRMS { lastVoiceAt = now; voicedSamples += n }
        let cap = Int(fmt.sampleRate * maxWindow)
        if seg.count > cap { seg.removeFirst(seg.count - cap) }
        lock.unlock()
    }

    func stop() {
        timer?.cancel(); timer = nil
        lock.lock(); let p = proc; proc = nil; lock.unlock()
        p?.terminate()   // kill any in-flight whisper-cli so it doesn't keep burning CPU / leak
        q.async {   // runs after any in-flight transcribeIfReady() (serial queue) so the wav isn't recreated post-delete
            self.lock.lock(); self.seg.removeAll(); self.running = false; self.lock.unlock()
            try? FileManager.default.removeItem(at: self.wavURL)
        }
    }

    /// Convert an incoming buffer (mic native / 48 kHz tap) to 16 kHz mono float.
    private func to16kMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == fmt { return buffer }
        lock.lock()
        if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: fmt) }
        let c = converter; lock.unlock()
        guard let c else { return nil }
        let ratio = fmt.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: capacity) else { return nil }
        var fed = false; var err: NSError?
        c.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        return (err == nil && out.frameLength > 0) ? out : nil
    }

    /// Timer handler (on `q`). Snapshots the segment, decides finalize vs volatile, runs whisper-cli.
    private func transcribeIfReady() {
        lock.lock()
        if running { lock.unlock(); return }
        let samples = seg, started = startedAt, lastVoice = lastVoiceAt, voiced = voicedSamples
        lock.unlock()
        let now = ProcessInfo.processInfo.systemUptime
        let dur = Double(samples.count) / fmt.sampleRate
        guard dur >= minDur else { return }
        // Whisper hallucinates ("Thank you", "Thanks for watching"…) on silence — only run it once the segment holds
        // enough real voice; otherwise drop the silence untranscribed.
        if Double(voiced) / fmt.sampleRate < minVoicedSec {
            lock.lock(); seg.removeAll(keepingCapacity: true); startedAt = 0; voicedSamples = 0; lock.unlock()
            return
        }
        let finalize = (now - lastVoice > silenceGap) || (now - started > maxDur)
        lock.lock(); running = true; lock.unlock()
        let text = runWhisper(samples)
        if !text.isEmpty { onUpdate(text, finalize) }
        lock.lock()
        if finalize { seg.removeAll(keepingCapacity: true); startedAt = 0; voicedSamples = 0 }
        running = false
        lock.unlock()
    }

    private func runWhisper(_ samples: [Float]) -> String {
        guard FileManager.default.isExecutableFile(atPath: cfg.whisperCli),
              FileManager.default.fileExists(atPath: cfg.whisperModel) else {
            elog("whisperlive[\(label)]: whisper-cli or model missing (\(cfg.whisperCli))"); return ""
        }
        guard writeWav(samples) else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cfg.whisperCli)
        // -nt: plain text (no timestamps); -bs 1: greedy for latency; half the cores to spare the engine.
        var args = ["-m", cfg.whisperModel, "-f", wavURL.path, "-l", lang, "-nt", "-np", "-sns",
                    "-bs", "1", "-t", String(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))]
        if !hints.isEmpty { args += ["--prompt", hints] }   // same proper-noun dictionary as the saved transcript
        p.arguments = args
        let out = Pipe(); p.standardOutput = out
        p.standardError = FileHandle.nullDevice   // discard stderr — draining a Pipe we never read can deadlock waitUntilExit()
        lock.lock(); proc = p; lock.unlock()
        do { try p.run() } catch { elog("whisperlive run: \(error)"); lock.lock(); proc = nil; lock.unlock(); return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        lock.lock(); proc = nil; lock.unlock()
        let raw = String(data: data, encoding: .utf8) ?? ""
        let text = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }.joined(separator: " ")
        if text.isEmpty || p.terminationStatus != 0 { elog("whisperlive[\(label)]: whisper exit \(p.terminationStatus), raw \(raw.count) chars → empty") }
        return text
    }

    private func writeWav(_ samples: [Float]) -> Bool {
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return false }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        do {
            let file = try AVAudioFile(forWriting: wavURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buf); return true
        } catch { elog("whisperlive writeWav: \(error)"); return false }
    }
}

/// Cloud live engine: streams 16 kHz linear16 audio to Deepgram's realtime WebSocket API and maps its
/// interim/final results onto the overlay's volatile/final line model. THE ONLY feature that sends audio
/// off-device, and only while the overlay is open with this engine selected — the saved whisper transcript
/// stays fully local. Needs an API key (Settings → Live; `MR_DEEPGRAM_KEY`). No SDK — URLSessionWebSocketTask.
final class DeepgramLiveTranscriber: NSObject, LiveTranscribing, URLSessionWebSocketDelegate {
    private let label: String
    private let locale: Locale
    private let onUpdate: (String, Bool) -> Void
    private let onLocale: ((Locale) -> Void)?
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let q = DispatchQueue(label: "macrec.deepgram", qos: .userInitiated)   // serializes task/pending/stopped
    private var converter: AVAudioConverter?   // feed thread only (one capture thread per transcriber)
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pending = Data()               // audio awaiting send (batch ≈100 ms — DG likes 20–250 ms chunks)
    private var stopped = false
    private var keepalive: DispatchSourceTimer?
    private var lastSentAt = 0.0
    private let batchBytes = 1600 * 2          // 100 ms of 16 kHz Int16

    /// The key the user stored (Keychain, migrating any pre-Keychain prefs value). Used by both the
    /// engine and the Settings field, so upgraders see their key instead of an empty field. The legacy
    /// value is removed ONLY once the Keychain write is confirmed (a failed save must not drop the
    /// sole stored credential).
    static var storedKey: String? {
        if let k = Keychain.get("deepgram") { return k }
        guard !Keychain.disabled else { return nil }   // never migrate (and never delete the legacy pref) in tests
        if let k = Pref.d.string(forKey: Pref.deepgramKey), !k.isEmpty {
            if Keychain.set("deepgram", k) { Pref.d.removeObject(forKey: Pref.deepgramKey) }
            return k
        }
        return nil
    }
    static var apiKey: String { storedKey ?? ProcessInfo.processInfo.environment["MR_DEEPGRAM_KEY"] ?? "" }

    init(label: String, locale: Locale, onLocale: ((Locale) -> Void)? = nil,
         onUpdate: @escaping (String, Bool) -> Void) {
        self.label = label; self.locale = locale; self.onLocale = onLocale; self.onUpdate = onUpdate
    }

    /// The realtime endpoint for a language + hint keywords (each term becomes a `keywords` boost —
    /// same proper-noun dictionary as the saved transcript; capped for URL sanity). Pure + testable.
    static func listenURL(lang: String, keywords: [String]) -> URL {
        var comps = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        var items: [URLQueryItem] = [
            .init(name: "model", value: "nova-2"),
            .init(name: "language", value: lang),
            .init(name: "encoding", value: "linear16"),
            .init(name: "sample_rate", value: "16000"),
            .init(name: "channels", value: "1"),
            .init(name: "interim_results", value: "true"),
            .init(name: "smart_format", value: "true"),
            .init(name: "punctuate", value: "true"),
            .init(name: "endpointing", value: "300"),
        ]
        items += keywords.prefix(30).map { URLQueryItem(name: "keywords", value: $0) }
        comps.queryItems = items
        return comps.url!
    }

    func start() {
        onLocale?(locale)
        let key = Self.apiKey
        guard !key.isEmpty else {
            onUpdate("Deepgram API key not set — Settings → Live (or MR_DEEPGRAM_KEY)", true)
            elog("deepgram[\(label)]: no API key — engine idle")
            return
        }
        let lang = locale.language.languageCode?.identifier ?? "en"
        q.async { [self] in   // all connection state (task/session/pending/lastSentAt/stopped) lives on q
            guard !stopped else { return }   // stop() can land before this block on a quick toggle — don't orphan a socket
            // Hints do file IO + an EventKit query — computed HERE, not on the main thread that
            // builds engines (review finding: a slow hints file/calendar froze the app).
            let keywords = parseHintTerms(transcriptionHints(start: Date(), end: Date()))
            var req = URLRequest(url: Self.listenURL(lang: lang, keywords: keywords))
            req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
            let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let t = s.webSocketTask(with: req)
            session = s; task = t
            lastSentAt = ProcessInfo.processInfo.systemUptime   // fresh socket = no send gap yet
            t.resume()
            receiveLoop(t)
            // Deepgram closes the socket after ~10 s without messages; audio normally flows continuously
            // (silence included), but a paused/stalled source shouldn't kill the connection.
            let ka = DispatchSource.makeTimerSource(queue: q)
            ka.schedule(deadline: .now() + 5, repeating: 5)
            ka.setEventHandler { [weak self] in
                guard let self, let t = self.task, !self.stopped else { return }
                if ProcessInfo.processInfo.systemUptime - self.lastSentAt > 5 {
                    t.send(.string(#"{"type":"KeepAlive"}"#)) { _ in }
                }
            }
            ka.resume(); keepalive = ka
        }
        elog("deepgram[\(label)]: connecting (lang=\(lang))")
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        // No early `task` check — that state is q-confined (reading it here would race start()/stop()).
        // The no-connection case (e.g. missing key) just converts ~µs worth and drops inside q.async.
        guard let mono = toCanon(buffer), let ch = mono.floatChannelData?[0] else { return }
        let n = Int(mono.frameLength); guard n > 0 else { return }
        var i16 = [Int16](repeating: 0, count: n)
        for i in 0..<n { let v = max(-1, min(1, ch[i])); i16[i] = Int16(v * 32767) }
        let data = i16.withUnsafeBufferPointer { Data(buffer: $0) }   // little-endian on all Apple platforms
        q.async { [weak self] in
            guard let self, let t = self.task, !self.stopped else { return }
            self.pending.append(data)
            guard self.pending.count >= self.batchBytes else { return }
            let out = self.pending; self.pending.removeAll(keepingCapacity: true)
            self.lastSentAt = ProcessInfo.processInfo.systemUptime
            t.send(.data(out)) { [weak self] err in
                if let err, let self, !self.stopped { elog("deepgram[\(self.label)] send: \(err.localizedDescription)") }
            }
        }
    }

    func stop() {
        q.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            self.keepalive?.cancel(); self.keepalive = nil
            guard let t = self.task else { return }
            self.task = nil
            let s = self.session; self.session = nil
            if !self.pending.isEmpty {   // flush the sub-batch tail (≤100 ms) so the final caption isn't clipped
                let tail = self.pending; self.pending.removeAll(keepingCapacity: false)
                t.send(.data(tail)) { _ in }   // WebSocket frames are ordered — this precedes CloseStream
            }
            // Cancel only after CloseStream had its chance to flush — an immediate cancel can drop it.
            t.send(.string(#"{"type":"CloseStream"}"#)) { _ in
                t.cancel(with: .normalClosure, reason: nil)
                s?.finishTasksAndInvalidate()
            }
            elog("deepgram[\(self.label)]: stopped")
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.q.async {   // state (stopped) is q-confined; also serializes handle() with teardown
                guard !self.stopped else { return }
                switch result {
                case .failure(let err):
                    elog("deepgram[\(self.label)] receive: \(err.localizedDescription)")
                    self.onUpdate("(Deepgram connection lost: \(err.localizedDescription))", true)
                    // Dead connection → full teardown; otherwise KeepAlive keeps firing and feed()
                    // keeps queueing sends into a socket that will never deliver.
                    self.stopped = true
                    self.keepalive?.cancel(); self.keepalive = nil
                    self.task?.cancel(with: .abnormalClosure, reason: nil); self.task = nil
                    self.session?.finishTasksAndInvalidate(); self.session = nil
                case .success(let msg):
                    if case .string(let text) = msg { self.handle(text) }
                    self.receiveLoop(t)   // keep listening (also drains pings/metadata)
                }
            }
        }
    }

    func handle(_ text: String) {   // internal for the selftest (message-parsing is the pure logic here)
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if obj["type"] as? String == "Error" || obj["error"] != nil {
            elog("deepgram[\(label)] error message: \(text.prefix(300))")
            onUpdate("(Deepgram error — check the API key / log)", true)
            return
        }
        guard obj["type"] as? String == "Results",
              let channel = obj["channel"] as? [String: Any],
              let alts = channel["alternatives"] as? [[String: Any]],
              let transcript = alts.first?["transcript"] as? String else { return }
        let isFinal = obj["is_final"] as? Bool ?? false
        guard !transcript.isEmpty else { return }
        onUpdate(transcript, isFinal)
    }

    private func toCanon(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buf.format == fmt { return buf }
        if converter == nil || converter?.inputFormat != buf.format { converter = AVAudioConverter(from: buf.format, to: fmt) }
        guard let c = converter else { return nil }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * fmt.sampleRate / buf.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var fed = false; var err: NSError?
        c.convert(to: out, error: &err) { _, s in if fed { s.pointee = .noDataNow; return nil }; fed = true; s.pointee = .haveData; return buf }
        return (err == nil && out.frameLength > 0) ? out : nil
    }
}

/// Cloud live engine #2: OpenAI's Realtime transcription API (gpt-4o-transcribe). Streams pcm16 @ 24 kHz
/// over a WebSocket; the server VAD segments turns, transcript DELTAS append to the current line and
/// `completed` finalizes it. Same rules as Deepgram: sends audio off-device ONLY while the overlay runs
/// with this engine selected; API key in the Keychain (Settings → Live; `MR_OPENAI_KEY`). No SDK.
final class OpenAILiveTranscriber: NSObject, LiveTranscribing, URLSessionWebSocketDelegate {
    private let label: String
    private let locale: Locale
    private let onUpdate: (String, Bool) -> Void
    private let onLocale: ((Locale) -> Void)?
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private let q = DispatchQueue(label: "macrec.openailive", qos: .userInitiated)   // confines all connection state
    private var converter: AVAudioConverter?   // feed thread only (one capture thread per transcriber)
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pending = Data()               // audio awaiting send (batch ≈100 ms)
    private var accum = ""                     // running transcript of the current turn (deltas append)
    private var stopped = false
    private let batchBytes = 2400 * 2          // 100 ms of 24 kHz Int16

    static var storedKey: String? { Keychain.get("openai") }
    static var apiKey: String { storedKey ?? ProcessInfo.processInfo.environment["MR_OPENAI_KEY"] ?? "" }

    /// Realtime endpoint for a BASE (an OpenAI-compatible proxy/gateway host, e.g. a corporate LLM
    /// proxy). Accepts `https://`, `http://`, `wss://` or `ws://` bases, with or without a path prefix;
    /// http(s) is mapped to the matching WebSocket scheme and `/v1/realtime?intent=transcription` is
    /// appended. Empty/invalid → the official endpoint. Pure + testable (see `macrec selftest`).
    static func realtimeURL(base: String) -> URL {
        let official = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
        let raw = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return official }
        guard var comps = URLComponents(string: raw), let scheme = comps.scheme?.lowercased(), comps.host != nil else {
            // Don't echo the raw value — a pasted URL can carry credentials/sensitive query params.
            elog("openailive: invalid base URL (redacted) — using the official endpoint")
            return official
        }
        switch scheme {
        case "https": comps.scheme = "wss"
        case "http":  comps.scheme = "ws"
        case "wss", "ws": break
        default:
            elog("openailive: unsupported base scheme '\(scheme)' — using the official endpoint")
            return official
        }
        while comps.path.hasSuffix("/") { comps.path.removeLast() }
        comps.path += "/v1/realtime"
        // Gateways often need their own query params — keep them, but never duplicate `intent`.
        var items = (comps.queryItems ?? []).filter { $0.name != "intent" }
        items.append(URLQueryItem(name: "intent", value: "transcription"))
        comps.queryItems = items
        return comps.url ?? official
    }
    /// The configured base: an EXPLICITLY saved value (even empty = "use the official endpoint")
    /// beats the MR_OPENAI_BASE env — otherwise clearing the Settings field couldn't override the env.
    static var configuredBase: String {
        if Pref.d.object(forKey: Pref.openaiBase) != nil { return Pref.d.string(forKey: Pref.openaiBase) ?? "" }
        return ProcessInfo.processInfo.environment["MR_OPENAI_BASE"] ?? ""
    }
    static var endpoint: URL { realtimeURL(base: configuredBase) }

    /// The transcription-session config event: pcm16 in, server VAD segmenting turns; a non-empty hints
    /// dictionary rides the transcription prompt (same proper nouns as the saved transcript). Pure + testable.
    static func sessionConfig(lang: String, hints: String) -> [String: Any] {
        var transcription: [String: Any] = ["model": "gpt-4o-transcribe", "language": lang]
        if !hints.isEmpty { transcription["prompt"] = hints }
        return ["type": "transcription_session.update", "session": [
            "input_audio_format": "pcm16",
            "input_audio_transcription": transcription,
            "turn_detection": ["type": "server_vad", "silence_duration_ms": 500],
        ] as [String: Any]]
    }

    init(label: String, locale: Locale, onLocale: ((Locale) -> Void)? = nil,
         onUpdate: @escaping (String, Bool) -> Void) {
        self.label = label; self.locale = locale; self.onLocale = onLocale; self.onUpdate = onUpdate
    }

    func start() {
        onLocale?(locale)
        let key = Self.apiKey
        guard !key.isEmpty else {
            onUpdate("OpenAI API key not set — Settings → Live (or MR_OPENAI_KEY)", true)
            elog("openailive[\(label)]: no API key — engine idle")
            return
        }
        let lang = locale.language.languageCode?.identifier ?? "en"
        let endpoint = Self.endpoint
        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        q.async { [self] in
            guard !stopped else { return }   // stop() can land before this block on a quick toggle
            let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let t = s.webSocketTask(with: req)
            session = s; task = t
            t.resume()
            receiveLoop(t)
            // Configure the transcription session: raw pcm16 in, server VAD segmenting turns. The hints
            // dictionary rides the transcription prompt (same proper nouns as the saved transcript).
            let cfg = Self.sessionConfig(lang: lang, hints: transcriptionHints(start: Date(), end: Date()))
            if let d = try? JSONSerialization.data(withJSONObject: cfg), let str = String(data: d, encoding: .utf8) {
                t.send(.string(str)) { [weak self] err in
                    if let err, let self, !self.stopped { elog("openailive[\(self.label)] config: \(err.localizedDescription)") }
                }
            }
        }
        elog("openailive[\(label)]: connecting (lang=\(lang), host=\(endpoint.host ?? "?"))")
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        // No off-queue state peeks (q-confined); the no-connection case just converts ~µs and drops.
        guard let mono = toCanon(buffer), let ch = mono.floatChannelData?[0] else { return }
        let n = Int(mono.frameLength); guard n > 0 else { return }
        var i16 = [Int16](repeating: 0, count: n)
        for i in 0..<n { let v = max(-1, min(1, ch[i])); i16[i] = Int16(v * 32767) }
        let data = i16.withUnsafeBufferPointer { Data(buffer: $0) }   // little-endian on all Apple platforms
        q.async { [weak self] in
            guard let self, self.task != nil, !self.stopped else { return }
            self.pending.append(data)
            guard self.pending.count >= self.batchBytes else { return }
            let out = self.pending; self.pending.removeAll(keepingCapacity: true)
            self.sendAudio(out)
        }
    }

    private func sendAudio(_ chunk: Data) {   // caller is on q
        guard let t = task else { return }
        let msg = #"{"type":"input_audio_buffer.append","audio":""# + chunk.base64EncodedString() + #""}"#
        t.send(.string(msg)) { [weak self] err in
            if let err, let self, !self.stopped { elog("openailive[\(self.label)] send: \(err.localizedDescription)") }
        }
    }

    func stop() {
        q.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            guard let t = self.task else { return }
            self.task = nil
            let s = self.session; self.session = nil
            // Best-effort final flush: append any sub-batch tail, then COMMIT so the server transcribes
            // what it's holding before the close (server VAD normally commits on silence, but we're
            // closing now). A commit on a too-small/empty buffer can error — harmless: `stopped` is
            // already set, so the receive loop drops any late error event.
            let finish = {
                t.send(.string(#"{"type":"input_audio_buffer.commit"}"#)) { _ in
                    t.cancel(with: .normalClosure, reason: nil)
                    s?.finishTasksAndInvalidate()
                }
            }
            if !self.pending.isEmpty {
                let msg = #"{"type":"input_audio_buffer.append","audio":""# + self.pending.base64EncodedString() + #""}"#
                self.pending.removeAll(keepingCapacity: false)
                t.send(.string(msg)) { _ in finish() }
            } else {
                finish()
            }
            elog("openailive[\(self.label)]: stopped")
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.q.async {   // state is q-confined; also serializes handle() with teardown
                guard !self.stopped else { return }
                switch result {
                case .failure(let err):
                    elog("openailive[\(self.label)] receive: \(err.localizedDescription)")
                    self.onUpdate("(OpenAI connection lost: \(err.localizedDescription))", true)
                    // Dead connection → full teardown; nothing should keep sending into it.
                    self.stopped = true
                    self.task?.cancel(with: .abnormalClosure, reason: nil); self.task = nil
                    self.session?.finishTasksAndInvalidate(); self.session = nil
                case .success(let msg):
                    if case .string(let text) = msg { self.handle(text) }
                    self.receiveLoop(t)
                }
            }
        }
    }

    func handle(_ text: String) {   // internal for the selftest (event parsing is the pure logic here)
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = obj["delta"] as? String, !delta.isEmpty else { return }
            accum += delta                     // OpenAI deltas APPEND (Deepgram interims replace)
            onUpdate(accum, false)
        case "conversation.item.input_audio_transcription.completed":
            let transcript = obj["transcript"] as? String ?? accum
            accum = ""
            guard !transcript.isEmpty else { return }
            onUpdate(transcript, true)
        case "error":
            elog("openailive[\(label)] error: \(text.prefix(300))")
            onUpdate("(OpenAI error — check the API key / log)", true)
        default: break   // session.created / committed / speech_started … — not caption-relevant
        }
    }

    private func toCanon(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buf.format == fmt { return buf }
        if converter == nil || converter?.inputFormat != buf.format { converter = AVAudioConverter(from: buf.format, to: fmt) }
        guard let c = converter else { return nil }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * fmt.sampleRate / buf.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var fed = false; var err: NSError?
        c.convert(to: out, error: &err) { _, s in if fed { s.pointee = .noDataNow; return nil }; fed = true; s.pointee = .haveData; return buf }
        return (err == nil && out.frameLength > 0) ? out : nil
    }
}

/// Cloud live engine #3: Gladia realtime v2 — notable for broad language coverage including Korean
/// STREAMING (the reason it was picked over AssemblyAI, whose realtime is English-centric). Two-step
/// protocol: a REST init (X-Gladia-Key) returns a single-use WebSocket URL; audio then streams as
/// binary pcm16 @ 16 kHz. Same rules as the other cloud engines: audio leaves the device ONLY while
/// the overlay runs with this engine; key in the Keychain (Settings → Live; MR_GLADIA_KEY). No SDK.
final class GladiaLiveTranscriber: NSObject, LiveTranscribing, URLSessionWebSocketDelegate {
    private let label: String
    private let locale: Locale
    private let onUpdate: (String, Bool) -> Void
    private let onLocale: ((Locale) -> Void)?
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let q = DispatchQueue(label: "macrec.gladialive", qos: .userInitiated)   // confines all connection state
    private var converter: AVAudioConverter?   // feed thread only (one capture thread per transcriber)
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pending = Data()               // audio awaiting send (batch ≈100 ms)
    private var stopped = false
    private let batchBytes = 1600 * 2          // 100 ms of 16 kHz Int16

    static var storedKey: String? { Keychain.get("gladia") }
    static var apiKey: String { storedKey ?? ProcessInfo.processInfo.environment["MR_GLADIA_KEY"] ?? "" }

    init(label: String, locale: Locale, onLocale: ((Locale) -> Void)? = nil,
         onUpdate: @escaping (String, Bool) -> Void) {
        self.label = label; self.locale = locale; self.onLocale = onLocale; self.onUpdate = onUpdate
    }

    /// The REST-init body: stream format + language + the hints dictionary as custom vocabulary.
    /// Pure + testable (see `macrec selftest`).
    static func initBody(lang: String, vocabulary: [String]) -> [String: Any] {
        var body: [String: Any] = [
            "encoding": "wav/pcm", "sample_rate": 16000, "bit_depth": 16, "channels": 1,
        ]
        if !lang.isEmpty { body["language_config"] = ["languages": [lang], "code_switching": false] }
        if !vocabulary.isEmpty {
            body["realtime_processing"] = ["custom_vocabulary": true,
                                           "custom_vocabulary_config": ["vocabulary": vocabulary]] as [String: Any]
        }
        return body
    }

    func start() {
        onLocale?(locale)
        let key = Self.apiKey
        guard !key.isEmpty else {
            onUpdate("Gladia API key not set — Settings → Live (or MR_GLADIA_KEY)", true)
            elog("gladialive[\(label)]: no API key — engine idle")
            return
        }
        let lang = locale.language.languageCode?.identifier ?? ""
        elog("gladialive[\(label)]: requesting session (lang=\(lang.isEmpty ? "auto" : lang))")
        q.async { [self] in
            guard !stopped else { return }
            // Hints do file IO + an EventKit query — computed HERE, not on the main thread that
            // builds engines (review finding: a slow hints file/calendar froze the app).
            let vocab = parseHintTerms(transcriptionHints(start: Date(), end: Date()))
            var req = URLRequest(url: URL(string: "https://api.gladia.io/v2/live")!)
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "X-Gladia-Key")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: Self.initBody(lang: lang, vocabulary: vocab))
            startSession(req)
        }
    }

    private func startSession(_ req: URLRequest) {   // on q
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            self.q.async {
                guard !self.stopped else { return }   // stop() can land before the session arrives
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                guard err == nil, (200..<300).contains(status), let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let urlStr = obj["url"] as? String, let wsURL = URL(string: urlStr) else {
                    elog("gladialive[\(self.label)] init failed: status \(status) \(err?.localizedDescription ?? "")")
                    self.onUpdate("(Gladia session failed — check the API key / log)", true)
                    return
                }
                let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                let t = s.webSocketTask(with: wsURL)   // single-use URL carries the auth token
                self.session = s; self.task = t
                t.resume()
                self.receiveLoop(t)
                if !self.pending.isEmpty {   // flush the PRE-ROLL buffered while the REST init ran
                    let out = self.pending; self.pending.removeAll(keepingCapacity: true)
                    t.send(.data(out)) { [weak self] err in
                        if let err, let self, !self.stopped { elog("gladialive[\(self.label)] preroll send: \(err.localizedDescription)") }
                    }
                }
            }
        }.resume()
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        // No off-queue state peeks (q-confined); the no-connection case just converts ~µs and drops.
        guard let mono = toCanon(buffer), let ch = mono.floatChannelData?[0] else { return }
        let n = Int(mono.frameLength); guard n > 0 else { return }
        var i16 = [Int16](repeating: 0, count: n)
        for i in 0..<n { let v = max(-1, min(1, ch[i])); i16[i] = Int16(v * 32767) }
        let data = i16.withUnsafeBufferPointer { Data(buffer: $0) }   // little-endian on all Apple platforms
        q.async { [weak self] in
            guard let self, !self.stopped else { return }
            // PRE-ROLL: unlike the other engines, the socket only exists after Gladia's REST init
            // returns — audio spoken during that round trip must buffer, not drop (review finding:
            // the opening words after enabling captions were lost). Cap ~30 s in case init hangs.
            self.pending.append(data)
            if self.pending.count > 16000 * 2 * 30 { self.pending.removeFirst(self.pending.count - 16000 * 2 * 30) }
            guard let t = self.task, self.pending.count >= self.batchBytes else { return }
            let out = self.pending; self.pending.removeAll(keepingCapacity: true)
            t.send(.data(out)) { [weak self] err in
                if let err, let self, !self.stopped { elog("gladialive[\(self.label)] send: \(err.localizedDescription)") }
            }
        }
    }

    func stop() {
        q.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            guard let t = self.task else { return }
            self.task = nil
            let s = self.session; self.session = nil
            if !self.pending.isEmpty {   // flush the sub-batch tail so the final words aren't clipped
                let tail = self.pending; self.pending.removeAll(keepingCapacity: false)
                t.send(.data(tail)) { _ in }   // frames are ordered — precedes stop_recording
            }
            t.send(.string(#"{"type":"stop_recording"}"#)) { _ in
                t.cancel(with: .normalClosure, reason: nil)
                s?.finishTasksAndInvalidate()
            }
            elog("gladialive[\(self.label)]: stopped")
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.q.async {   // state is q-confined; also serializes handle() with teardown
                guard !self.stopped else { return }
                switch result {
                case .failure(let err):
                    elog("gladialive[\(self.label)] receive: \(err.localizedDescription)")
                    self.onUpdate("(Gladia connection lost: \(err.localizedDescription))", true)
                    self.stopped = true   // dead connection → full teardown
                    self.task?.cancel(with: .abnormalClosure, reason: nil); self.task = nil
                    self.session?.finishTasksAndInvalidate(); self.session = nil
                case .success(let msg):
                    if case .string(let text) = msg { self.handle(text) }
                    self.receiveLoop(t)
                }
            }
        }
    }

    func handle(_ text: String) {   // internal for the selftest (message parsing is the pure logic here)
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "transcript":
            guard let d = obj["data"] as? [String: Any],
                  let utterance = d["utterance"] as? [String: Any],
                  let t = utterance["text"] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            onUpdate(t.trimmingCharacters(in: .whitespaces), (d["is_final"] as? Bool) ?? false)
        case "error":
            elog("gladialive[\(label)] error: \(text.prefix(300))")
            onUpdate("(Gladia error — check the API key / log)", true)
        default: break   // audio_chunk acks / lifecycle events — not caption-relevant
        }
    }

    private func toCanon(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buf.format == fmt { return buf }
        if converter == nil || converter?.inputFormat != buf.format { converter = AVAudioConverter(from: buf.format, to: fmt) }
        guard let c = converter else { return nil }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * fmt.sampleRate / buf.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var fed = false; var err: NSError?
        c.convert(to: out, error: &err) { _, s in if fed { s.pointee = .noDataNow; return nil }; fed = true; s.pointee = .haveData; return buf }
        return (err == nil && out.frameLength > 0) ? out : nil
    }
}

/// Which speakers to transcribe for the live overlay. Each source runs its own on-device analyzer,
/// so transcribing one instead of two roughly halves inference load → lower latency. Default is
/// `.other` (the remote party / system audio): you already know what you said, and it's the cheaper
/// path. (The saved whisper transcript always covers everyone regardless of this setting.)
enum LiveSource: String {
    case both, other, me
    static var current: LiveSource { LiveSource(rawValue: Pref.d.string(forKey: Pref.liveSource) ?? "") ?? .other }
}

/// Option lists for the live-caption overlay's control bar. These settings live on the overlay itself
/// (not the Settings window) so changes apply immediately. Index 0 of each is the default. Language
/// names are endonyms (each language's own name for itself) for quick recognition; translation is prefixed with →.
enum LiveCaptionOptions {
    static let langValues   = ["", "ko", "ja", "en", "zh-Hans", "es", "fr", "de"]
    static let langTitles   = ["System", "한국어", "日本語", "English", "中文", "Español", "Français", "Deutsch"]
    static let sourceValues = ["other", "both", "me"]
    static let sourceTitles = ["Them", "Both", "Me"]
    static let transValues  = ["", "ko", "ja", "en", "zh-Hans", "es", "fr", "de"]
    static let transTitles  = ["Off", "→한국어", "→日本語", "→English", "→中文", "→Español", "→Français", "→Deutsch"]
}

/// Owns the two per-source transcribers + optional translator + the floating caption window.
@available(macOS 26, *)
final class LiveCaptions {
    static let shared = LiveCaptions()
    // mic/sys are written on the main thread (start/stop) and read on the audio queue (feed*), so a
    // lock guards the reference swap. LiveTranscriber.feed is itself thread-safe.
    private let srcLock = NSLock()
    private let feedQueue = DispatchQueue(label: "macrec.live.feed", qos: .userInitiated)
    private var mic: (any LiveTranscribing)?
    private var sys: (any LiveTranscribing)?
    private var translator: LiveTranslator?   // nil = no live translation
    private var window: LiveCaptionWindow?
    struct CapLine {
        var speaker: String
        var text: String
        var final: Bool
        var time: Date                      // creation time — doubles as the line's identity
        var transParts: [String?] = []      // per-sentence translations, positional (async-safe)
        var transRequested = 0              // how many complete sentences have been sent to translate
        var transFinal = false              // the authoritative full-text translation has landed
        var transTail: String? = nil        // live translation of the UNFINISHED tail (volatile)
        var tailInFlight = false            // ONE tail request at a time — landing refires with the newest tail
        var tailLastSent = ""               // tail text of the in-flight/last request (skip if unchanged)
        var tailSentAt: Double = 0          // floor between back-to-back refires
        var translated: String? {
            // IN-ORDER prefix only: sentence translations land async, and rendering part 2 while
            // part 1 is still in flight would show the translation out of order. The tail always
            // renders last (it is by definition the newest region).
            var parts: [String] = []
            for p in transParts { guard let p else { break }; parts.append(p) }
            if let t = transTail { parts.append(t) }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }
    private var lines: [CapLine] = []
    private var mineLabel = ""   // label used for the mic track (for speaker coloring)
    private var showLabels = true   // false in single-speaker modes (one voice → the label is redundant)
    // Last-applied live config — so reconfigure() can no-op on unchanged values and avoid needless
    // analyzer rebuilds (each rebuild re-pays the ~model warm-up).
    private var curLocaleId = "", curEngine = "", curSource = "", curTranslateId = ""
    private var engineGen = 0   // bumped on translator rebuild; a translate Task from an older gen is ignored
    private let maxLines = 12
    private(set) var active = false

    /// Menu toggle (main thread).
    func toggle() { active ? stop() : start() }

    /// Settings were saved: the engine picker and the engine itself must reflect them without the user
    /// closing and reopening the overlay (an engine switched off stayed in the menu until then).
    func settingsSaved() {
        guard active else { return }
        window?.reloadEngineChoices()
        reconfigure()
    }

    func start() {
        guard !active else { return }
        active = true; lines = []; renderScheduled = false   // clear any coalescing state left by a prior session
        let win = LiveCaptionWindow(
            onClose: { [weak self] in self?.stop() },
            onReconfigure: { [weak self] in self?.reconfigure() },   // language / source / translate changed
            onRestyle: { [weak self] in self?.render() })            // text size / timestamps changed
        window = win; win.show()
        buildEngine()
        elog("live: captions ON")
    }

    private typealias LiveCfg = (locale: Locale, engine: LiveEngine, source: LiveSource, translateId: String)

    /// Snapshot the current live prefs.
    private func liveConfig() -> LiveCfg {
        let capId = Pref.d.string(forKey: Pref.captionLang) ?? ""   // "" = system
        let locale = capId.isEmpty ? Locale.current : Locale(identifier: capId)
        return (locale, LiveEngine.current, LiveSource.current, Pref.d.string(forKey: Pref.translateTo) ?? "")
    }

    /// Reports the resolved language into the overlay title.
    private func makeOnLocale() -> (Locale) -> Void {
        { [weak self] loc in
            let name = Locale.current.localizedString(forLanguageCode: loc.language.languageCode?.identifier ?? "")
                ?? loc.identifier(.bcp47)
            DispatchQueue.main.async { self?.window?.setLanguage(name) }
        }
    }

    /// (Re)build the translator (nil = off, or target == caption language).
    private func rebuildTranslator(_ cfg: LiveCfg) {
        engineGen &+= 1   // invalidate any in-flight translate Task started against the previous translator
        translator = nil
        if !cfg.translateId.isEmpty,
           Locale(identifier: cfg.translateId).language.languageCode?.identifier != cfg.locale.language.languageCode?.identifier {
            translator = LiveTranslator(source: cfg.locale.language, target: Locale.Language(identifier: cfg.translateId))
        }
    }

    /// Full build of the transcriber(s) + translator from current prefs (warms up the analyzer). Serves
    /// both the first start and a locale/engine/source change; the window is reused across all of them.
    private func buildEngine() {
        let cfg = liveConfig()
        window?.setPreparing()   // title shows "starting…" until the analyzer warms up (onLocale replaces it)
        let (mine, theirs) = speakerLabels(forLanguage: cfg.locale.language.languageCode?.identifier)
        mineLabel = mine
        // A single speaker needs no label, so hide it (render then uses a neutral color).
        showLabels = (cfg.source == .both)
        rebuildTranslator(cfg)
        let onLocale = makeOnLocale()
        var m: (any LiveTranscribing)?, s: (any LiveTranscribing)?
        if cfg.source == .both || cfg.source == .me {
            m = makeTranscriber(label: mine, locale: cfg.locale, onLocale: onLocale) { [weak self] t, f in self?.post(mine, t, f) }
        }
        if cfg.source == .both || cfg.source == .other {
            s = makeTranscriber(label: theirs, locale: cfg.locale, onLocale: m == nil ? onLocale : nil) { [weak self] t, f in self?.post(theirs, t, f) }
        }
        srcLock.lock(); mic = m; sys = s; srcLock.unlock()
        m?.start(); s?.start()
        curLocaleId = cfg.locale.identifier; curEngine = cfg.engine.rawValue
        curSource = cfg.source.rawValue; curTranslateId = cfg.translateId
        elog("live: engine built (engine=\(cfg.engine.rawValue), locale=\(cfg.locale.identifier), source=\(cfg.source.rawValue), translate=\(cfg.translateId.isEmpty ? "off" : cfg.translateId))")
    }

    /// Build the configured engine for one source. Extensible: add a LiveEngine case + a branch here.
    private func makeTranscriber(label: String, locale: Locale, onLocale: ((Locale) -> Void)?,
                                 onUpdate: @escaping (String, Bool) -> Void) -> any LiveTranscribing {
        switch LiveEngine.current {
        case .whisper:  return WhisperLiveTranscriber(label: label, locale: locale, onLocale: onLocale, onUpdate: onUpdate)
        case .deepgram: return DeepgramLiveTranscriber(label: label, locale: locale, onLocale: onLocale, onUpdate: onUpdate)
        case .openai:   return OpenAILiveTranscriber(label: label, locale: locale, onLocale: onLocale, onUpdate: onUpdate)
        case .gladia:   return GladiaLiveTranscriber(label: label, locale: locale, onLocale: onLocale, onUpdate: onUpdate)
        case .apple:    return LiveTranscriber(label: label, locale: locale, onLocale: onLocale, onUpdate: onUpdate)
        }
    }

    /// Apply an overlay control-bar change. Keeps the transcript history; only rebuilds the analyzer
    /// (which re-warms) when the locale/engine/source actually changed. Re-picking the active value is a
    /// no-op, and a translate-only change swaps just the translator (instant, no warm-up).
    private func reconfigure() {
        guard active else { return }
        let cfg = liveConfig()
        let sameSources = cfg.locale.identifier == curLocaleId && cfg.engine.rawValue == curEngine && cfg.source.rawValue == curSource
        let sameTranslate = cfg.translateId == curTranslateId
        if sameSources && sameTranslate { return }   // nothing changed (e.g. re-picked the active language)
        // Keep the transcript history on every change — the overlay filters what it SHOWS by source
        // (Both→Me hides the other party's lines; switching back to Both reveals them again).
        for i in lines.indices where !lines[i].final { lines[i].final = true }
        // Caption language changed → remap kept lines' speaker labels so their label/color stay correct.
        let (oldMine, oldTheirs) = speakerLabels(forLanguage: Locale(identifier: curLocaleId).language.languageCode?.identifier)
        let (newMine, newTheirs) = speakerLabels(forLanguage: cfg.locale.language.languageCode?.identifier)
        if oldMine != newMine || oldTheirs != newTheirs {
            for i in lines.indices {
                if lines[i].speaker == oldMine { lines[i].speaker = newMine }
                else if lines[i].speaker == oldTheirs { lines[i].speaker = newTheirs }
            }
        }
        if !sameSources {
            srcLock.lock(); let m = mic, s = sys; mic = nil; sys = nil; srcLock.unlock()
            m?.stop(); s?.stop()
            buildEngine()   // rebuild (warms up); the existing captions stay on screen
            elog("live: reconfigured (rebuild)")
        } else {
            rebuildTranslator(cfg); curTranslateId = cfg.translateId   // translate-only → instant
            elog("live: reconfigured (translator only)")
        }
        renderScheduled = false; render()
    }

    func stop() {
        guard active else { return }
        active = false; renderScheduled = false   // drop any pending coalesced render (so a restart isn't suppressed)
        srcLock.lock(); let m = mic, s = sys; mic = nil; sys = nil; srcLock.unlock()
        m?.stop(); s?.stop()
        translator = nil
        let w = window; window = nil; w?.close()
        elog("live: captions OFF")
    }

    // Audio-queue feeds (no-op when inactive). Snapshot the ref under the lock, then feed outside it.
    // Feeds arrive on the capture threads (the tap's real-time IOProc for system audio!). Hop onto a
    // normal queue so the format conversion never runs on the real-time audio thread (avoids glitches).
    func feedMic(_ b: AVAudioPCMBuffer) { srcLock.lock(); let m = mic; srcLock.unlock(); if let m { feedQueue.async { m.feed(b) } } }
    func feedSystem(_ b: AVAudioPCMBuffer) { srcLock.lock(); let s = sys; srcLock.unlock(); if let s { feedQueue.async { s.feed(b) } } }

    private func post(_ speaker: String, _ text: String, _ final: Bool) {
        DispatchQueue.main.async { [weak self] in self?.apply(speaker, text, final) }
    }
    private func apply(_ speaker: String, _ text: String, _ final: Bool) {
        guard active else { return }
        // Transcript-level echo suppression (belt to the AEC's braces): a mic line whose text is a
        // (garbled) copy of a recent far-end line is the speakers leaking back in, not the user.
        if speaker == mineLabel, EchoCanceller.shared.enabled {
            let cutoff = Date().addingTimeInterval(-10)
            let isEcho = lines.contains { $0.speaker != mineLabel && $0.time > cutoff
                                          && isLikelyEcho(mine: text, theirs: $0.text) }
            if isEcho {
                // Drop it — and if this was updating an in-progress mine line that just BECAME an
                // echo (the garbled copy streams in over a few updates), remove that line too.
                if let i = lines.lastIndex(where: { $0.speaker == speaker && !$0.final }) {
                    lines.remove(at: i)
                    render()
                }
                return
            }
        }
        // Engines often emit partials with a leading space — trim so lines never render indented.
        let text = text.trimmingCharacters(in: .whitespaces)
        // Update this speaker's in-progress (non-final) line, or start a new one.
        let i: Int
        if let j = lines.lastIndex(where: { $0.speaker == speaker && !$0.final }) {
            lines[j].text = text; lines[j].final = final
            i = j
        } else {
            lines.append(CapLine(speaker: speaker, text: text, final: final, time: Date()))
            i = lines.count - 1
        }
        let removed = max(0, lines.count - maxLines)
        if removed > 0 { lines.removeFirst(removed) }
        render()
        // Sentence-streamed translation: translate each sentence THE MOMENT it completes inside the
        // growing partial (punctuation boundary) — timely, and the translation line only ever
        // APPENDS whole sentences, so it never rewrites under the reader (the old partial-retranslate
        // made both lines move at once; the finals-only attempt landed seconds late — user reports).
        // Finalization then re-translates the full text ONCE as the authoritative version.
        translateNewSentences(at: i - removed, final: final)
    }

    private func translateNewSentences(at index: Int, final: Bool) {
        guard let translator, lines.indices.contains(index) else { return }
        let line = lines[index]
        guard !line.text.isEmpty, !line.transFinal else { return }
        let gen = engineGen
        let lineTime = line.time
        if final {
            lines[index].transFinal = true
            // The streamed translation (confirmed sentences + last tail) is already on screen.
            // Re-translating the FULL text here was the longest possible request on a session
            // that serializes — the NEXT line's first tail queued behind it ("second line is
            // slow" — user report). Promote what's shown instead; only lines that never got any
            // streaming translation (e.g. translation just switched on) still pay a full pass.
            if lines[index].translated != nil {
                if let tail = lines[index].transTail {
                    lines[index].transParts.append(tail)   // freeze the volatile tail as the last part
                    lines[index].transTail = nil
                }
                return
            }
            let full = line.text
            Task { [weak self] in
                guard let out = await translator.translate(full) else { return }
                await MainActor.run {
                    guard let self, self.engineGen == gen,
                          let k = self.lines.lastIndex(where: { $0.time == lineTime }) else { return }
                    self.lines[k].transParts = [out]   // authoritative full pass (had nothing streamed)
                    self.lines[k].transTail = nil
                    self.render()
                }
            }
            return
        }
        let complete = completeSentences(line.text)
        if complete.count > line.transRequested {
            for idx in line.transRequested..<complete.count {
                let sentence = complete[idx]
                Task { [weak self] in
                    guard let out = await translator.translate(sentence) else { return }
                    await MainActor.run {
                        guard let self, self.engineGen == gen,
                              let k = self.lines.lastIndex(where: { $0.time == lineTime }),
                              !self.lines[k].transFinal else { return }
                        while self.lines[k].transParts.count <= idx { self.lines[k].transParts.append(nil) }
                        self.lines[k].transParts[idx] = out
                        self.render()
                    }
                }
            }
            lines[index].transRequested = complete.count
        }
        // Live tail — SELF-CLOCKING: exactly one request in flight; the moment a result lands it
        // refires with the newest tail if it moved. Latency = the model's own speed (~0.2-0.4 s),
        // not a timer (the old 0.5 s throttle read as "not real-time" — user report). A small
        // 0.15 s floor stops single-keystroke hammering.
        let tail = currentTail(of: line.text, complete: complete)
        if tail.isEmpty, lines[index].transTail != nil, complete.count == lines[index].transRequested {
            lines[index].transTail = nil   // tail fully consumed into confirmed sentences
        }
        fireTailTranslation(lineTime: lineTime, gen: gen)
    }

    /// The words after the last completed sentence — the volatile region live translation chases.
    private func currentTail(of text: String, complete: [String]) -> String {
        if let last = complete.last, let r = text.range(of: last, options: .backwards) {
            return String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return complete.isEmpty ? text : ""
    }

    private func fireTailTranslation(lineTime: Date, gen: Int) {
        guard let translator, engineGen == gen,
              let k = lines.lastIndex(where: { $0.time == lineTime }) else { return }
        let tail = currentTail(of: lines[k].text, complete: completeSentences(lines[k].text))
        guard shouldFireTailTranslation(tail: tail, lastSent: lines[k].tailLastSent,
                                        inFlight: lines[k].tailInFlight, final: lines[k].transFinal) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let wait = max(0, 0.15 - (now - lines[k].tailSentAt))
        lines[k].tailInFlight = true
        lines[k].tailLastSent = tail
        lines[k].tailSentAt = now + wait
        Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            let out = await translator.translate(tail)
            await MainActor.run {
                guard let self, self.engineGen == gen else { return }
                guard let k = self.lines.lastIndex(where: { $0.time == lineTime }) else { return }
                self.lines[k].tailInFlight = false
                if !self.lines[k].transFinal, let out {
                    self.lines[k].transTail = out
                    self.render()
                }
                self.fireTailTranslation(lineTime: lineTime, gen: gen)   // tail moved meanwhile? chase it
            }
        }
    }
    // Volatile results arrive many times/sec from BOTH transcribers; rebuilding the whole overlay
    // each time churns the UI thread. Coalesce to ~10 fps (negligible vs the engine's own latency).
    private var renderScheduled = false
    private func render() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            guard self.active else { return }
            let showTS = Pref.bool(Pref.liveTimestamps, "MR_LIVE_TIMESTAMPS", true)
            let fontSize = CGFloat(Pref.dbl(Pref.liveFontSize, "MR_LIVE_FONT_SIZE", 14))
            // Show only the lines matching the current source (Both = all; Me = mine; Them = the rest).
            let mode = LiveSource(rawValue: self.curSource) ?? .both
            let visible = self.lines.filter { l in
                switch mode {
                case .both:  return true
                case .me:    return l.speaker == self.mineLabel
                case .other: return l.speaker != self.mineLabel
                }
            }
            self.window?.render(visible.map { (speaker: $0.speaker, text: $0.text, translated: $0.translated,
                                        time: $0.time, mine: $0.speaker == self.mineLabel, inProgress: !$0.final) },
                                showTimestamps: showTS, fontSize: fontSize, showLabels: self.showLabels)
        }
    }
}

/// The overlay's opacity slider moves the BACKDROP only, never the captions. Fading the whole window
/// (`panel.alphaValue`) fades its children too, so at the low end the very text the overlay exists to
/// show disappeared along with the background. The range bottoms out at ZERO — a fully transparent
/// backdrop is the closed-caption look, captions floating over whatever is behind them — which is safe
/// precisely because the text keeps its own contrast (see the halo in `render`). Pure + selftested.
let captionOpacityRange: ClosedRange<Double> = 0.0...1.0
func captionBackdropAlpha(_ pref: Double) -> CGFloat {
    CGFloat(min(captionOpacityRange.upperBound, max(captionOpacityRange.lowerBound, pref)))
}

/// What a subtitle actually shows. A film subtitle is not a transcript log: it is the last thing said,
/// centred, with the translation carrying the line and the original demoted to a whisper above it. When
/// there is no translation the original IS the subtitle. Pure + selftested.
func subtitleLine(original: String, translated: String?) -> (main: String, secondary: String?) {
    guard let t = translated?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
        return (original, nil)
    }
    return (t, original.isEmpty ? nil : original)
}

/// Subtitles are read at a glance from across the room: bigger than the log's body text, and never
/// smaller than legible. Pure + selftested.
func subtitleFontSize(_ base: CGFloat) -> CGFloat { max(18, base + 6) }

/// How many lines a subtitle shows. A film shows one utterance, two lines at most — a scrolling wall of
/// history is the thing that makes an overlay read as a log. Pure + selftested.
let subtitleMaxLines = 2

/// The window outline exists so a transparent LOG still reads as a window you can grab. A subtitle is
/// not a window — a rectangle drawn around a film subtitle is exactly what breaks the illusion.
/// Pure + selftested.
func captionEdgeVisible(subtitle: Bool) -> Bool { !subtitle }

/// Do the captions have to carry their own contrast? Only when the backdrop is too faint to provide it.
/// A backplate behind text that already sits on a solid panel would just be a darker box on a dark box.
/// Pure + selftested.
func captionTextNeedsBackplate(backdropAlpha: CGFloat) -> Bool { backdropAlpha < 0.6 }

/// A view that is seen but never touched — it sits over the captions purely to draw the outline, so it
/// must not swallow clicks, text selection, or the window drag.
final class NonInteractiveView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Floating always-on-top panel showing the live captions. A compact control bar along the top holds
/// the live settings (language, who to transcribe, translation, text size, timestamps) so changes take
/// effect immediately; opacity is a drag slider on that bar. Nothing lives in the Settings window.
@available(macOS 26, *)
final class LiveCaptionWindow: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    /// The only thing the opacity slider fades. Layer-backed, not an NSVisualEffectView: the window
    /// server composites a `.behindWindow` material and ignores the view's alpha.
    private let backdrop = NSView()
    /// A faint outline that does NOT fade with the backdrop, so a transparent log still reads as a window.
    private let edge = NonInteractiveView()
    private let textView = NSTextView()
    private let onClose: () -> Void
    private let onReconfigure: () -> Void   // language / source / translation changed → rebuild the engine
    private let onRestyle: () -> Void        // text size / timestamps changed → just re-render
    private var suppressCloseCallback = false
    private let langPopup = NSPopUpButton(), sourcePopup = NSPopUpButton(), translatePopup = NSPopUpButton()
    private let tsToggle = NSButton(checkboxWithTitle: "Time", target: nil, action: nil)
    private let subToggle = NSButton(checkboxWithTitle: "Subtitle", target: nil, action: nil)
    private var controlsAccessory: NSTitlebarAccessoryViewController?   // the full control strip (collapsible)
    private let collapseBtn = NSButton()                                // chevron RIGHT NEXT TO the title text
    private var chevronLead: NSLayoutConstraint?                        // titlebar.centerX + titleWidth/2 + gap
    private var engineChoices: [LiveEngine] = []                        // exactly what the engine popup lists
    private let enginePopup = NSPopUpButton()                           // rebuilt when Settings change
    private static let titleIcon = "🎙️"           // beautifies the "macrec live" title

    @objc private func toggleControlBar() {
        setControlBar(collapsed: !(controlsAccessory?.isHidden ?? false))
    }
    private func setControlBar(collapsed: Bool, persist: Bool = true) {
        // The chevron lives in the TITLE ROW next to "macrec live" (user-requested spot; corners read
        // as window chrome, in-bar read as a caption setting). Collapsing just hides the whole strip —
        // its 32 pt comes back to the captions, and the chevron stays visible to expand again.
        controlsAccessory?.isHidden = collapsed
        let label = collapsed ? "Show caption controls" : "Hide caption controls"
        // The classic chevron pair, sized down a notch (user pick: compact/sheet-grabber read oddly here).
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        collapseBtn.image = NSImage(systemSymbolName: collapsed ? "chevron.down" : "chevron.up",
                                    accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        collapseBtn.setAccessibilityLabel(label)   // VoiceOver reads the BUTTON's label, not the image's
        collapseBtn.toolTip = label
        // Persist only on user toggles: writing during init would CREATE the defaults key on first
        // launch, and an existing key shadows the MR_LIVE_BAR_COLLAPSED env override forever after.
        if persist { Pref.d.set(collapsed, forKey: Pref.liveBarCollapsed) }
    }
    /// Set the window title AND keep the chevron glued to its right edge (the title is centered, so
    /// the offset is centerX + measured-title-width/2; re-measured on every title change).
    private func setTitle(_ s: String) {
        panel.title = s
        let font = NSFont.titleBarFont(ofSize: NSFont.smallSystemFontSize)   // utility-panel title size
        let w = (s as NSString).size(withAttributes: [.font: font]).width
        chevronLead?.constant = w / 2 + 8
    }

    init(onClose: @escaping () -> Void, onReconfigure: @escaping () -> Void, onRestyle: @escaping () -> Void) {
        self.onClose = onClose; self.onReconfigure = onReconfigure; self.onRestyle = onRestyle
        // NOT `.hudWindow`: that style inserts a full-window NSVisualEffectView as the theme frame's
        // bottom-most subview, under everything we own. It kept painting its dark material no matter
        // what the opacity slider did, so the overlay could never go fully transparent. We draw our own
        // dark fill (`backdrop`) instead and force the dark appearance so the titlebar still matches.
        panel = CaptionPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 172),   // default fits one more caption line
                             styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        super.init()
        panel.title = "\(Self.titleIcon) macrec live"
        // The window itself is ALWAYS fully opaque — see captionBackdropAlpha. Its content area draws
        // nothing (clear + non-opaque), so the only thing behind the captions is `backdrop`, whose
        // alpha the slider moves. Fading the window would fade the captions with it.
        panel.alphaValue = 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        // Text selection needs the panel to become key on a text click (nonactivating panels never do
        // by default → drag-select and ⌘C silently went to the previous app). "OnlyIfNeeded" keeps the
        // no-focus-steal behavior everywhere except selectable text.
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        // Controls live in the titlebar (a full-width accessory strip just below it) so they read as
        // window chrome, not content — the caption area stays clean. Each control applies immediately.
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .bottom
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 32))
        host.autoresizingMask = [.width]
        let bar = buildControlBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            host.heightAnchor.constraint(equalToConstant: 32),
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
            bar.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        accessory.view = host
        panel.addTitlebarAccessoryViewController(accessory)
        controlsAccessory = accessory

        // Collapse chevron in the TITLE ROW, glued to the right of "🎙️ macrec live · …". The titlebar
        // container is the close button's superview; the leading offset from center tracks the measured
        // title width (see setTitle). Sticky across sessions.
        collapseBtn.isBordered = false
        collapseBtn.bezelStyle = .regularSquare
        collapseBtn.imagePosition = .imageOnly
        collapseBtn.target = self
        collapseBtn.action = #selector(toggleControlBar)
        var chevronAttached = false
        if let closeBtn = panel.standardWindowButton(.closeButton), let titlebar = closeBtn.superview {
            collapseBtn.translatesAutoresizingMaskIntoConstraints = false
            titlebar.addSubview(collapseBtn)
            let lead = collapseBtn.leadingAnchor.constraint(equalTo: titlebar.centerXAnchor, constant: 60)
            chevronLead = lead
            // Y pins to the CLOSE BUTTON (which sits in the title row) — the titlebar container also
            // spans the bottom accessory strip, so its centerY would drop the chevron onto the controls.
            // The -1.5 pt trims the symbol's optical balance against the title text (fractional points
            // land on pixel boundaries on Retina; -2 sat visibly high after the glyph-size change).
            NSLayoutConstraint.activate([lead, collapseBtn.centerYAnchor.constraint(equalTo: closeBtn.centerYAnchor, constant: -1.5)])
            chevronAttached = true
        }
        setTitle(panel.title)   // measure the initial title → position the chevron
        // Never RESTORE a collapsed bar when the toggle couldn't be attached — there'd be no way back.
        let restoreCollapsed = chevronAttached && Pref.bool(Pref.liveBarCollapsed, "MR_LIVE_BAR_COLLAPSED", false)
        setControlBar(collapsed: restoreCollapsed, persist: false)

        // --- captions (scrollable text) fill the whole content (opacity moved up to the control bar) ---
        let content = panel.contentView!
        backdrop.frame = content.bounds
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        // The HUD panel's own dark fill, reproduced so we own its alpha. Pure black reads too heavy
        // against a bright screen at full opacity, so this matches the panel chrome's tone.
        backdrop.layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
        backdrop.alphaValue = captionBackdropAlpha(Pref.dbl(Pref.liveOpacity, "MR_LIVE_OPACITY", 1.0))
        content.addSubview(backdrop)
        let scroll = NSScrollView(frame: content.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay        // auto-hiding overlay scroller (no permanent bar)
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // Canonical scrollable NSTextView setup so vertical resizing + scrolling behave correctly.
        let size = scroll.contentSize
        textView.frame = NSRect(origin: .zero, size: size)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = false; textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        scroll.documentView = textView
        content.addSubview(scroll, positioned: .above, relativeTo: backdrop)

        // The outline goes on TOP so it isn't covered by the captions, and never fades with the
        // backdrop. It ignores the mouse (NonInteractiveView) so text selection and dragging still work.
        edge.frame = content.bounds
        edge.autoresizingMask = [.width, .height]
        edge.wantsLayer = true
        edge.layer?.borderWidth = 1
        edge.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        content.addSubview(edge, positioned: .above, relativeTo: scroll)
    }

    /// Reads back what the opacity slider actually moved — the captions must never be the thing that fades.
    var captionAlphasForTest: (window: CGFloat, backdrop: CGFloat, text: CGFloat) {
        (panel.alphaValue, backdrop.alphaValue, textView.alphaValue)
    }
    func setOpacityForTest(_ v: Double) { applyOpacity(v) }

    /// Nothing may paint behind the backdrop that the opacity slider cannot reach.
    var nothingPaintsBehindBackdropForTest: Bool {
        guard let frame = panel.contentView?.superview else { return false }
        return !frame.subviews.contains { $0 is NSVisualEffectView }
    }

    /// Does the backdrop actually PAINT? Asserting its alpha alone was a false all-clear.
    var backdropPaintsForTest: Bool {
        guard let content = panel.contentView, backdrop.wantsLayer,
              let fill = backdrop.layer?.backgroundColor, fill.alpha == 1,
              let bi = content.subviews.firstIndex(of: backdrop),
              let ti = content.subviews.firstIndex(where: { $0 is NSScrollView }) else { return false }
        return bi < ti && backdrop.frame.size == content.bounds.size
    }

    /// The outline stays put and stays untouchable no matter where the opacity slider sits.
    var edgeSurvivesForTest: (visible: Bool, ignoresMouse: Bool) {
        let border = edge.layer.map { $0.borderWidth > 0 && ($0.borderColor?.alpha ?? 0) > 0 } ?? false
        return (border && edge.alphaValue == 1 && !edge.isHidden,
                edge.hitTest(NSPoint(x: 5, y: 5)) == nil)
    }

    /// UI TEST KIT (`macrec caption-snapshot <dir>`): show the overlay for real and capture the composited
    /// window at several opacities. The one thing to LOOK for: the background fades, the captions never do.
    ///
    /// It has to be a REAL screen capture. An offscreen `cacheDisplay` of this panel renders a blank
    /// white slab — a `.behindWindow` NSVisualEffectView is composited by the window server, not by the
    /// view's own drawing — so an offscreen snapshot would "pass" no matter what the opacity slider did.
    /// `screencapture -l<windowNumber>` grabs what the user actually sees. It needs the *calling*
    /// terminal's Screen Recording permission; without it the file never appears and we say so.
    func snapshotOpacities(_ values: [Double], to dir: URL) -> [URL] {
        var written: [URL] = []
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        render([(speaker: "me", text: "会議を始めましょう。", translated: "회의를 시작합시다.",
                 time: Date(timeIntervalSince1970: 0), mine: true, inProgress: false),
                (speaker: "them", text: "資料は共有済みです。", translated: "자료는 이미 공유했습니다.",
                 time: Date(timeIntervalSince1970: 4), mine: false, inProgress: true)],
               showTimestamps: true, fontSize: 14, showLabels: true)
        show()
        panel.orderFrontRegardless()
        for v in values {
            applyOpacity(v)
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))   // let the compositor settle
            let url = dir.appendingPathComponent(String(format: "overlay-opacity-%.2f.png", v))
            try? FileManager.default.removeItem(at: url)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l\(panel.windowNumber)", url.path]
            try? p.run(); p.waitUntilExit()
            if FileManager.default.fileExists(atPath: url.path) { written.append(url) }
        }
        panel.orderOut(nil)
        return written
    }

    /// Build the top control bar. Each control writes its Pref and fires the matching callback so the
    /// change is live: engine rebuild for language/source/translation, re-render for text size/timestamps.
    private func buildControlBar() -> NSStackView {
        func fill(_ p: NSPopUpButton, _ titles: [String], _ sel: Int, _ tip: String, _ action: Selector) {
            p.addItems(withTitles: titles); p.selectItem(at: sel)
            p.controlSize = .small; p.font = .systemFont(ofSize: 11); p.toolTip = tip
            p.target = self; p.action = action
            p.setContentHuggingPriority(.required, for: .horizontal)
        }
        let O = LiveCaptionOptions.self
        fill(langPopup, O.langTitles, idx(Pref.d.string(forKey: Pref.captionLang) ?? "", O.langValues),
             "Caption language", #selector(langChanged(_:)))
        fill(sourcePopup, O.sourceTitles, idx(LiveSource.current.rawValue, O.sourceValues),
             "Who to transcribe (fewer = faster)", #selector(sourceChanged(_:)))
        fill(translatePopup, O.transTitles, idx(Pref.d.string(forKey: Pref.translateTo) ?? "", O.transValues),
             "Translate captions to…", #selector(translateChanged(_:)))
        let aMinus = NSButton(title: "A－", target: self, action: #selector(fontSmaller))
        let aPlus  = NSButton(title: "A＋", target: self, action: #selector(fontBigger))
        for b in [aMinus, aPlus] { b.controlSize = .small; b.bezelStyle = .roundRect; b.font = .systemFont(ofSize: 11) }
        aMinus.toolTip = "Smaller text"; aPlus.toolTip = "Bigger text"
        tsToggle.controlSize = .small; tsToggle.font = .systemFont(ofSize: 11); tsToggle.toolTip = "Show timestamps"
        tsToggle.state = Pref.bool(Pref.liveTimestamps, "MR_LIVE_TIMESTAMPS", true) ? .on : .off
        tsToggle.target = self; tsToggle.action = #selector(tsToggled(_:))
        subToggle.controlSize = .small; subToggle.font = .systemFont(ofSize: 11)
        subToggle.toolTip = "Subtitle view — the last line, centred, translation first"
        subToggle.state = Pref.bool(Pref.liveSubtitle, "MR_LIVE_SUBTITLE", false) ? .on : .off
        subToggle.target = self; subToggle.action = #selector(subtitleToggled(_:))
        tsToggle.isEnabled = subToggle.state == .off
        // Engine select box — only engines that are switched on AND have what they need to run.
        engineChoices = selectableLiveEngines(LiveEngine.allCases, ready: { $0.isReady }, enabled: { $0.isEnabled })
        fill(enginePopup, engineChoices.map { $0.title }, engineChoices.firstIndex(of: .current) ?? 0,
             "Engine — Apple: fast · Whisper: accurate. Add a key in Settings to unlock the cloud engines.",
             #selector(engineChanged(_:)))
        // Opacity drag slider, now on the top bar (was a bottom strip).
        let opacity = NSSlider(value: Double(captionBackdropAlpha(Pref.dbl(Pref.liveOpacity, "MR_LIVE_OPACITY", 1.0))),
                               minValue: captionOpacityRange.lowerBound, maxValue: captionOpacityRange.upperBound,
                               target: self, action: #selector(opacityChanged(_:)))
        opacity.controlSize = .mini; opacity.toolTip = "Background opacity (captions stay readable)"
        opacity.translatesAutoresizingMaskIntoConstraints = false
        opacity.widthAnchor.constraint(equalToConstant: 72).isActive = true
        // A small leading icon per select box says what it controls, without text-label clutter.
        func icon(_ name: String, _ tip: String) -> NSImageView {
            let iv = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: tip) ?? NSImage())
            iv.symbolConfiguration = .init(pointSize: 12, weight: .regular)
            iv.contentTintColor = .secondaryLabelColor; iv.toolTip = tip
            iv.setContentHuggingPriority(.required, for: .horizontal); return iv
        }
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let copyBtn = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!,
                               target: self, action: #selector(copyTranscript))
        copyBtn.isBordered = false; copyBtn.imagePosition = .imageOnly
        copyBtn.toolTip = "Copy the transcript (selection, or everything)"
        copyBtn.setAccessibilityLabel("Copy transcript")
        copyBtn.setContentHuggingPriority(.required, for: .horizontal)
        let bar = NSStackView(views: [
            icon("cpu", "Engine"), enginePopup,
            icon("globe", "Caption language"), langPopup,
            icon("person.2", "Who to transcribe"), sourcePopup,
            icon("character.bubble", "Translate to"), translatePopup,
            spacer, copyBtn, aMinus, aPlus, subToggle, tsToggle, opacity])
        bar.orientation = .horizontal; bar.alignment = .centerY; bar.spacing = 5; bar.distribution = .fill
        return bar
    }

    private func idx<T: Equatable>(_ v: T, _ arr: [T]) -> Int { arr.firstIndex(of: v) ?? 0 }

    @objc private func langChanged(_ s: NSPopUpButton) {
        Pref.d.set(LiveCaptionOptions.langValues[max(0, s.indexOfSelectedItem)], forKey: Pref.captionLang); onReconfigure()
    }
    @objc private func sourceChanged(_ s: NSPopUpButton) {
        Pref.d.set(LiveCaptionOptions.sourceValues[max(0, s.indexOfSelectedItem)], forKey: Pref.liveSource); onReconfigure()
    }
    @objc private func translateChanged(_ s: NSPopUpButton) {
        Pref.d.set(LiveCaptionOptions.transValues[max(0, s.indexOfSelectedItem)], forKey: Pref.translateTo); onReconfigure()
    }
    @objc private func fontSmaller() { adjustFont(-2) }
    @objc private func fontBigger()  { adjustFont(+2) }
    private func adjustFont(_ delta: CGFloat) {
        let next = min(28, max(11, CGFloat(Pref.dbl(Pref.liveFontSize, "MR_LIVE_FONT_SIZE", 14)) + delta))
        Pref.d.set(Double(next), forKey: Pref.liveFontSize); onRestyle()
    }
    @objc private func tsToggled(_ s: NSButton) { Pref.d.set(s.state == .on, forKey: Pref.liveTimestamps); onRestyle() }
    @objc private func subtitleToggled(_ s: NSButton) {
        Pref.d.set(s.state == .on, forKey: Pref.liveSubtitle)
        tsToggle.isEnabled = s.state == .off   // a subtitle has no timestamps; don't offer a dead switch
        onRestyle()
    }
    /// Copy the current selection — or the whole transcript when nothing is selected.
    @objc private func copyTranscript() {
        let sel = textView.selectedRange()
        let text = (sel.length > 0 ? (textView.string as NSString).substring(with: sel) : textView.string)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    /// Settings changed while the overlay is open: an engine switched off (or a key just added) has to
    /// show up in the picker NOW — it was built once, at window creation, and never revisited.
    func reloadEngineChoices() {
        engineChoices = selectableLiveEngines(LiveEngine.allCases, ready: { $0.isReady }, enabled: { $0.isEnabled })
        enginePopup.removeAllItems()
        enginePopup.addItems(withTitles: engineChoices.map { $0.title })
        enginePopup.selectItem(at: engineChoices.firstIndex(of: .current) ?? 0)
    }
    var engineChoicesForTest: [LiveEngine] { engineChoices }

    @objc private func engineChanged(_ s: NSPopUpButton) {
        guard let e = engineAtPopupIndex(s.indexOfSelectedItem, choices: engineChoices) else { return }
        Pref.d.set(e.rawValue, forKey: Pref.liveEngine); onReconfigure()
    }

    @objc private func opacityChanged(_ s: NSSlider) { applyOpacity(s.doubleValue) }

    private func applyOpacity(_ v: Double) {
        backdrop.alphaValue = captionBackdropAlpha(v)   // background only — captions stay fully opaque
        Pref.d.set(v, forKey: Pref.liveOpacity)
        onRestyle()   // the captions' outline depends on the backdrop — re-render at the new opacity
    }

    func show() {
        if let f = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.maxX - panel.frame.width - 24, y: f.minY + 24))
        }
        panel.orderFrontRegardless()
    }
    func close() { suppressCloseCallback = true; panel.close() }

    /// Show the active transcription language in the title bar (human name, e.g. "🎙️ macrec live · Korean").
    func setLanguage(_ name: String) { setTitle("\(Self.titleIcon) macrec live · \(name)") }
    /// Shown while the analyzer warms up (model/ANE load) — the overlay is otherwise blank for ~10s.
    func setPreparing() { setTitle("\(Self.titleIcon) macrec live · starting…") }

    private let tsFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// Render for glanceable reading. With both speakers each gets a distinct tint (teal = you, orange =
    /// them) on a bold label; a single speaker drops the label and uses the primary color. All text starts
    /// at one shared column via a tab stop, and wrapped lines hang-indent to that same column — so line 2+
    /// aligns flush under the text regardless of the timestamp/label prefix width.
    /// Film-subtitle presentation: the last utterance, centred, translation leading and the original
    /// demoted above it. Contrast lives BEHIND the glyphs (a plate) — never in them: a blurred halo
    /// smears the strokes and a `strokeWidth` outline reads as a heavier font weight.
    private func renderSubtitle(_ lines: [(speaker: String, text: String, translated: String?, time: Date, mine: Bool, inProgress: Bool)],
                                fontSize: CGFloat) {
        let size = subtitleFontSize(fontSize)
        let mainFont = NSFont.systemFont(ofSize: size, weight: .semibold)
        let subFont = NSFont.systemFont(ofSize: max(11, size - 6), weight: .regular)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineHeightMultiple = 1.15
        para.paragraphSpacing = 6
        // No plate: a `.backgroundColor` run paints a hard rectangle per line. Contrast goes behind the
        // glyphs, never into them — a `strokeWidth` outline reads as a heavier font weight.
        let halo = NSShadow()
        halo.shadowColor = NSColor.black.withAlphaComponent(0.85)
        halo.shadowBlurRadius = 2
        halo.shadowOffset = NSSize(width: 0, height: -1)

        let out = NSMutableAttributedString()
        for (i, l) in lines.suffix(subtitleMaxLines).enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            let (main, secondary) = subtitleLine(original: l.text, translated: l.translated)
            if let secondary {
                out.append(NSAttributedString(string: secondary + "\n", attributes: [
                    .font: subFont, .foregroundColor: NSColor.secondaryLabelColor,
                    .shadow: halo, .paragraphStyle: para]))
            }
            out.append(NSAttributedString(string: main, attributes: [
                .font: mainFont, .foregroundColor: NSColor.labelColor,
                .shadow: halo, .paragraphStyle: para]))
        }
        textView.textStorage?.setAttributedString(out)
        textView.scrollToEndOfDocument(nil)
    }

    func render(_ lines: [(speaker: String, text: String, translated: String?, time: Date, mine: Bool, inProgress: Bool)],
                showTimestamps: Bool, fontSize: CGFloat, showLabels: Bool) {
        let tsFont = NSFont.monospacedDigitSystemFont(ofSize: max(9, fontSize - 3), weight: .regular)
        let labelFont = NSFont.boldSystemFont(ofSize: fontSize)
        let textFont = NSFont.systemFont(ofSize: fontSize)
        let transFont = NSFont.systemFont(ofSize: fontSize)   // same size as the caption — translation is the point
        func w(_ s: String, _ f: NSFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: f]).width }
        // Shared text column = timestamp width (constant, monospaced) + widest speaker label + a gap.
        let tsW = showTimestamps ? w("00:00:00  ", tsFont) : 0
        let labelW = showLabels ? (lines.map { w("\($0.speaker)  ", labelFont) }.max() ?? 0) : 0
        // A subtitle is not the log with its chrome off: timestamps and labels go regardless of toggles.
        let subtitleMode = Pref.bool(Pref.liveSubtitle, "MR_LIVE_SUBTITLE", false)
        edge.isHidden = !captionEdgeVisible(subtitle: subtitleMode)
        if subtitleMode {
            renderSubtitle(lines, fontSize: fontSize)
            return
        }
        let hasPrefix = showTimestamps || showLabels
        let col = hasPrefix ? tsW + labelW + 8 : 0
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = 0; para.headIndent = col
        para.lineHeightMultiple = 1.1; para.paragraphSpacing = 4
        if hasPrefix { para.tabStops = [NSTextTab(textAlignment: .left, location: col)]; para.defaultTabInterval = col }
        let markFont = NSFont.systemFont(ofSize: max(9, fontSize - 4))   // the arrow is a footnote, not a headline
        let trans = NSMutableParagraphStyle()
        trans.firstLineHeadIndent = col; trans.headIndent = col + w("↳ ", markFont); trans.lineHeightMultiple = 1.1
        let out = NSMutableAttributedString()
        for (i, l) in lines.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            let tint: NSColor = l.mine ? .systemTeal : .systemOrange   // colors the LABEL only (both-speaker mode)
            if showTimestamps {
                out.append(NSAttributedString(string: "\(tsFormatter.string(from: l.time))  ", attributes: [
                    .font: tsFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
            }
            if showLabels {
                out.append(NSAttributedString(string: "\(l.speaker)  ", attributes: [
                    .font: labelFont, .foregroundColor: tint, .paragraphStyle: para]))
            }
            if hasPrefix { out.append(NSAttributedString(string: "\t", attributes: [.font: textFont, .paragraphStyle: para])) }
            out.append(NSAttributedString(string: l.text, attributes: [   // text stays neutral like single-speaker mode
                .font: textFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: para]))
            if l.inProgress {   // still transcribing this line → typing indicator inside the text
                out.append(NSAttributedString(string: (l.text.isEmpty ? "…" : " …"), attributes: [
                    .font: textFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
            }
            if let t = l.translated, !t.isEmpty {
                out.append(NSAttributedString(string: "\n↳ ", attributes: [
                    .font: markFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: trans]))
                // The translation carries the SPEAKER's tint (source text stays neutral) — the two
                // layers separate at a glance instead of being two near-identical white lines.
                out.append(NSAttributedString(string: t, attributes: [
                    .font: transFont, .foregroundColor: tint.withAlphaComponent(0.95), .paragraphStyle: trans]))
            }
        }
        // Over a see-through backdrop the captions sit on whatever is behind the window — light slides,
        // white documents — and vanish. The two treatments that DON'T work: a blurred halo smears the
        // thin strokes, and a negative `strokeWidth` outlines the glyphs, which reads as a heavier
        // weight. Neither may touch the letterforms. So put the contrast BEHIND them, as broadcast
        // captions do: a dark plate hugging the text, drawn only when the backdrop can't do the job.
        if captionTextNeedsBackplate(backdropAlpha: captionBackdropAlpha(Pref.dbl(Pref.liveOpacity, "MR_LIVE_OPACITY", 1.0))) {
            out.addAttribute(.backgroundColor, value: NSColor.black.withAlphaComponent(0.55),
                             range: NSRange(location: 0, length: out.length))
        }
        textView.textStorage?.setAttributedString(out)
        textView.scrollToEndOfDocument(nil)
    }

    // User clicked the panel's close button → tear the session down (unless we closed it ourselves).
    func windowWillClose(_ notification: Notification) { if !suppressCloseCallback { onClose() } }
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
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === toggleItem { return pauseItemEnabled(paused: paused, schedulePaused: schedulePaused, hasEngine: engine != nil) }
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
        let activity: SummaryActivity = mode == .off ? .off : SummaryStatus.shared.current
        let hm = DateFormatter(); hm.locale = Locale(identifier: "en_US_POSIX"); hm.dateFormat = "HH:mm"
        summaryLine.title = summaryMenuTitle(activity) { hm.string(from: $0) }
        pendingSummaryAction = summaryRowAction(activity, lastOutput: SummaryStatus.shared.lastOutput)
        summaryLine.isEnabled = pendingSummaryAction != .none   // enablement and the click are one decision

        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        digestLine.title = digestMenuTitle(enabled: Pref.bool(Pref.dailyDigest, "MR_DAILY_DIGEST", false),
                                           dueTime: Pref.str(Pref.dailyDigestTime, "MR_DAILY_DIGEST_TIME", "20:00"),
                                           lastRun: Pref.explicit(Pref.dailyDigestLastRun, ""),
                                           today: day.string(from: Date()))
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
        Pref.d.set(day, forKey: Pref.dailyDigestLastRun)
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
        guard !existingNotes.contains(URL(fileURLWithPath: out).standardizedFileURL.path) else {
            elog("digest: \(out) is an existing transcript — refusing to overwrite it")
            Notifier.push(title: "Daily digest skipped",
                          body: "The file name resolves onto an existing note (\(URL(fileURLWithPath: out).lastPathComponent)). "
                              + "Change it in Settings › Summaries › File name.")
            return
        }
        // Exclude the digest itself: it lands in a folder we just scanned and shares the day prefix.
        let inputs = dailyDigestInputs(day: day, transcripts: transcripts, summaries: summaries, excluding: out)
        guard !inputs.isEmpty else { elog("digest: no meetings on \(day) — skipping"); return }
        let runner = SummaryRunner(rawValue: Pref.explicit(Pref.summaryRunner, "MR_SUMMARY_RUNNER")) ?? .claude
        let inline = effectiveSummaryPrompt(inline: Pref.explicit(Pref.dailyPrompt, "MR_DAILY_DIGEST_PROMPT"),
                                            filePath: Pref.explicit(Pref.dailyPromptFile, "MR_DAILY_DIGEST_PROMPT_FILE"))
        let prompt = inline.isEmpty ? defaultDailyDigestPrompt : inline
        guard let cmd = dailyDigestInvocation(runner: runner, prompt: prompt,
                                              inputs: inputs, outPath: out) else { return }
        elog("digest: \(day) — \(inputs.count) inputs → \(out)")
        SummaryStatus.shared.started("daily digest \(day)")
        runPostProcessCommand(cmd) { status in
            elog("digest: \(day) finished (exit \(status))")
            // The last-run marker is already set, so a failed digest won't retry until tomorrow.
            if status == 0 {
                SummaryStatus.shared.finished("daily digest \(day)", at: Date(), output: out)
                Notifier.push(title: "Daily digest ready", body: "\(day) — \(inputs.count) meetings", filePath: out)
            } else {
                let why = reapFailedPostProcess(outPath: out)
                SummaryStatus.shared.failed("daily digest \(day)", at: Date(), reason: why)
                Notifier.push(title: "Daily digest failed",
                              body: why ?? "The summary command exited with code \(status) — check Settings › Summaries.")
            }
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

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { visiblePaneIndexes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let p = panesForTest[visiblePaneIndexes[row]]
        let cell = SidebarCell()
        // Monochrome SF Symbol + label — a clean nav column. SidebarCell tints the icon white when
        // the row is selected (accent fill); muted secondary otherwise.
        let icon = NSImageView(image: NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.title) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: p.title)
        label.font = .systemFont(ofSize: 13)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.imageView = icon      // outlet wiring lets the source-list style manage selection colors
        cell.textField = label
        cell.addSubview(icon); cell.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
        ])
        return cell
    }

    /// Keeps the selected pane accent-filled regardless of where keyboard focus sits — see SidebarRowView.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SidebarRowView() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebarList.selectedRow
        guard row >= 0, visiblePaneIndexes.indices.contains(row) else { return }
        selectPane(visiblePaneIndexes[row])
    }
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
        if args.first == "selftest" {
            var fails = 0
            func check(_ name: String, _ ok: Bool) { print("\(ok ? "ok  " : "FAIL") \(name)"); if !ok { fails += 1 } }
            // Live-caption locale mapping (regression: Locale.current can be en_KR, which SpeechTranscriber
            // rejects with "unsupported locale" — must map to a supported one).
            let pool = ["fr-FR", "ko-KR", "zh-CN", "es-ES", "es-US", "en-GB", "en-AU", "en-US", "ja-JP"].map { Locale(identifier: $0) }
            func pick(_ id: String) -> String? { pickSpeechLocale(requested: Locale(identifier: id), from: pool)?.identifier(.bcp47) }
            check("en_KR → en-US (prefer -US)", pick("en_KR") == "en-US")
            check("ko_KR → ko-KR (exact-ish)",  pick("ko_KR") == "ko-KR")
            check("ja_JP → ja-JP",              pick("ja_JP") == "ja-JP")
            check("en-GB → en-GB (exact)",      pick("en-GB") == "en-GB")
            check("es_MX → same-language es",   pick("es_MX") == "es-US" || pick("es_MX") == "es-ES")
            check("unsupported lang → nil",     pick("sw_TZ") == nil)
            check("labels ko → 나/상대",         speakerLabels(forLanguage: "ko") == ("나", "상대"))
            check("labels en → Me/Them",        speakerLabels(forLanguage: "en") == ("Me", "Them"))
            check("labels ja → 私/相手",         speakerLabels(forLanguage: "ja") == ("私", "相手"))
            // EchoCanceller (SpeexDSP AEC) framing/plumbing — deterministic, no audio device needed.
            // Guards the contract: the mic ALWAYS flows through (cumulative out ≈ in, ±one buffered frame),
            // whether or not a reference is present — a regression that starved the mic would fail here.
            let ecFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            func ecBuf(_ n: Int) -> AVAudioPCMBuffer {
                let b = AVAudioPCMBuffer(pcmFormat: ecFmt, frameCapacity: AVAudioFrameCount(n))!
                b.frameLength = AVAudioFrameCount(n)
                let ch = b.floatChannelData![0]; for i in 0..<n { ch[i] = 0.3 * sinf(Float(i) * 0.19) }
                return b
            }
            EchoCanceller.shared.reset()
            var ecIn = 0, ecOut = 0
            for _ in 0..<40 {
                EchoCanceller.shared.pushReference(ecBuf(171))                       // far-end reference
                ecOut += EchoCanceller.shared.cancelMic(ecBuf(171)).map { Int($0.frameLength) } ?? -99999
                ecIn += 171
            }
            check("AEC framing: mic flows (out ≈ in, with reference)", ecIn - ecOut >= 0 && ecIn - ecOut <= 512)
            EchoCanceller.shared.reset()   // no reference at all → mic must still pass through, never back up
            var nrIn = 0, nrOut = 0
            for _ in 0..<40 { nrOut += EchoCanceller.shared.cancelMic(ecBuf(171)).map { Int($0.frameLength) } ?? -99999; nrIn += 171 }
            check("AEC framing: mic flows (out ≈ in, no reference)", nrIn - nrOut >= 0 && nrIn - nrOut <= 256 * 5)
            // Jitter regression: the MEASURED real-world cadence — the mic delivering in ~32 ms clumps
            // (3×171) against a steady per-chunk reference — must trim ZERO samples and zero-pad ZERO
            // samples. Trimming/starving on this normal jitter shredded the reference continuity and
            // pinned real-call ERLE at ~6 dB (the "echo not improved" bug).
            EchoCanceller.shared.reset()
            _ = EchoCanceller.shared.cancelMic(ecBuf(256))     // anchor the pairing offset
            EchoCanceller.shared.pushReference(ecBuf(512))     // steady-state headroom like a live stream
            let jt = EchoCanceller.shared.trimsForTest, js = EchoCanceller.shared.starvesForTest
            for _ in 0..<100 {
                for _ in 0..<3 { EchoCanceller.shared.pushReference(ecBuf(171)) }   // tap: continuous
                for _ in 0..<3 { _ = EchoCanceller.shared.cancelMic(ecBuf(171)) }   // mic: clumped
            }
            check("AEC jitter: clumped mic delivery → 0 trimmed / 0 zero-padded samples",
                  EchoCanceller.shared.trimsForTest == jt && EchoCanceller.shared.starvesForTest == js)
            // Staleness invariant: the reference backlog the tap builds while the mic spins up must be
            // dropped when the stream anchors (first drain) — a persistent backlog makes the causal
            // filter cancel 0 dB for the whole session (regression found by adversarial review).
            EchoCanceller.shared.reset()
            EchoCanceller.shared.pushReference(ecBuf(6000))         // tap pre-fill during mic spin-up (capped)
            _ = EchoCanceller.shared.cancelMic(ecBuf(512))          // first drain anchors the pairing offset
            check("AEC staleness: startup backlog anchored to ≤ 512", EchoCanceller.shared.refDepthForTest <= 512)
            // Gap/reset invariant: buffered mic residue must not leak into a later stream.
            EchoCanceller.shared.reset()
            _ = EchoCanceller.shared.cancelMic(ecBuf(100))          // sub-frame residue stays buffered…
            let residue = EchoCanceller.shared.micDepthForTest == 100
            EchoCanceller.shared.reset()                            // …until a reset (or a mic-gap self-heal)
            check("AEC reset: buffered mic residue cleared", residue && EchoCanceller.shared.micDepthForTest == 0)
            // Constant-relation regression: the ring cap must outlast the gap-heal threshold (see maxRef).
            check("AEC invariant: ring cap covers the gap-heal window", EchoCanceller.shared.capCoversGapForTest)
            // Garbage tuning knobs (NaN / overflow env-style values) must not trap during preprocessor
            // (re)creation — Int32(Double.nan) crashes if unsanitized. Uses the real prefs path; cleaned up.
            Pref.d.set(Double.nan, forKey: "echoSuppress")
            Pref.d.set(1e308, forKey: "echoSuppressActive")
            _ = EchoCanceller.shared.cancelMic(ecBuf(256))   // ensure the echo state exists
            EchoCanceller.shared.reset()                     // recreates the preprocessor → reads the knobs
            // Getting ANY buffer back is the pass condition — an unsanitized Int32(NaN) traps before
            // returning. (0 frames is correct here: no reference yet → wait-for-ref holds the mic.)
            let knobOut = EchoCanceller.shared.cancelMic(ecBuf(256)).map { Int($0.frameLength) } ?? -1
            Pref.d.removeObject(forKey: "echoSuppress"); Pref.d.removeObject(forKey: "echoSuppressActive")
            EchoCanceller.shared.reset()                     // back to sane knobs for any later checks
            check("AEC knobs: garbage prefs don't crash preprocessor init", knobOut >= 0)
            // Deepgram engine: realtime-message parsing (interim → volatile, is_final → final, junk ignored).
            var dgGot: [(String, Bool)] = []
            let dg = DeepgramLiveTranscriber(label: "t", locale: Locale(identifier: "ko-KR")) { s, f in dgGot.append((s, f)) }
            dg.handle(#"{"type":"Results","is_final":false,"channel":{"alternatives":[{"transcript":"안녕하세요"}]}}"#)
            dg.handle(#"{"type":"Results","is_final":true,"channel":{"alternatives":[{"transcript":"안녕하세요 반갑습니다"}]}}"#)
            dg.handle(#"{"type":"Results","is_final":true,"channel":{"alternatives":[{"transcript":""}]}}"#)   // empty → dropped
            dg.handle(#"{"type":"Metadata","request_id":"x"}"#)                                                // non-result → dropped
            dg.handle("not json at all")                                                                       // junk → dropped
            check("deepgram: interim/final parsing", dgGot.count == 2
                  && dgGot[0] == ("안녕하세요", false) && dgGot[1] == ("안녕하세요 반갑습니다", true))
            // OpenAI Realtime engine: deltas APPEND to the running line; completed finalizes and resets.
            var oaGot: [(String, Bool)] = []
            let oa = OpenAILiveTranscriber(label: "t", locale: Locale(identifier: "ko-KR")) { s, f in oaGot.append((s, f)) }
            oa.handle(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"안녕"}"#)
            oa.handle(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"하세요"}"#)
            oa.handle(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"안녕하세요"}"#)
            oa.handle(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"반갑"}"#)   // new turn restarts
            oa.handle(#"{"type":"session.created"}"#)                                                    // non-caption → dropped
            oa.handle("junk")                                                                            // junk → dropped
            check("openai: delta accumulation + completed reset", oaGot.count == 4
                  && oaGot[0] == ("안녕", false) && oaGot[1] == ("안녕하세요", false)
                  && oaGot[2] == ("안녕하세요", true) && oaGot[3] == ("반갑", false))
            // OpenAI base-URL mapping (corporate proxies/gateways): https→wss, path prefix kept,
            // trailing slash trimmed, invalid/garbage falls back to the official endpoint.
            func oaURL(_ b: String) -> String { OpenAILiveTranscriber.realtimeURL(base: b).absoluteString }
            let oaOfficial = "wss://api.openai.com/v1/realtime?intent=transcription"
            check("openai base: empty → official", oaURL("") == oaOfficial)
            check("openai base: https proxy + path", oaURL("https://llm.corp.example/openai/") ==
                  "wss://llm.corp.example/openai/v1/realtime?intent=transcription")
            check("openai base: ws + port kept", oaURL("ws://localhost:8080") ==
                  "ws://localhost:8080/v1/realtime?intent=transcription")
            check("openai base: garbage → official", oaURL("ftp://nope") == oaOfficial && oaURL("::::") == oaOfficial)
            check("openai base: gateway query kept, intent deduped", oaURL("https://gw.example/x?intent=foo&team=a") ==
                  "wss://gw.example/x/v1/realtime?team=a&intent=transcription")
            // Saved-transcript scaffold localization: language-selected labels, and the old workflow
            // footer must never come back.
            let tDoc = TranscriptDoc(title: "T", day: "2026-07-05", hmStart: "10:00", hmEnd: "11:00", mins: 60,
                                     micVoiced: 1.0, sysVoiced: 2.0, modelName: "m.bin",
                                     audioLine: "- x", meta: "", excludes: "com.spotify.client",
                                     bodyMine: "나", bodyTheirs: "상대", body: "hello")
            let mdKo = tDoc.markdown(.forLanguage("ko")), mdEn = tDoc.markdown(.forLanguage("en")), mdJa = tDoc.markdown(.forLanguage("ja"))
            check("transcript md: section localized",
                  mdKo.contains("## 전사 (transcript)") && mdEn.contains("## Transcript") && mdJa.contains("## 文字起こし"))
            check("transcript md: labels localized",
                  mdKo.contains("- 시각:") && mdEn.contains("- Time:") && mdJa.contains("- 時刻:") && mdEn.contains("(60 min)"))
            check("transcript md: note keeps BODY speaker labels",
                  mdEn.contains("나 = microphone") && mdEn.contains("Excluded: com.spotify.client"))
            check("transcript md: workflow footer removed",
                  !mdKo.contains("자동 생성") && !mdKo.contains("topics/") && !mdEn.contains("topics/"))
            check("transcript l10n: failure + unknown lang fallback",
                  TranscriptL10n.forLanguage("ko").failureNote(model: "m").contains("전사 실패")
                  && TranscriptL10n.forLanguage("fr").section == "## Transcript"
                  && TranscriptL10n.forLanguage(nil).section == "## Transcript")
            // Post-process invocation builder — the built-in summary templates and the freeform mode.
            func inv(_ m: PostProcessMode, _ r: SummaryRunner, prompt: String = "P", shell: String = "", out: String = "") -> String? {
                postProcessInvocation(mode: m, runner: r, prompt: prompt, shellCmd: shell,
                                      transcriptPath: "/t/a b's.md", outDir: out)
            }
            check("post-process: off → nil, shell empty → nil",
                  inv(.off, .claude) == nil && inv(.shell, .claude) == nil)
            check("post-process: shell appends quoted path",
                  inv(.shell, .claude, shell: "./x.sh") == "./x.sh '/t/a b'\\''s.md'")
            check("post-process: claude summary template (mkdir + .partial promote)",
                  inv(.summary, .claude) == "mkdir -p '/t' && claude -p 'P' < '/t/a b'\\''s.md' "
                                          + "> '/t/a b'\\''s-sum.md.partial' "
                                          + "&& mv '/t/a b'\\''s-sum.md.partial' '/t/a b'\\''s-sum.md'")
            check("post-process: gemini summary template",
                  inv(.summary, .gemini)?.contains("gemini -p 'P'") == true)
            check("post-process: codex pipes prompt+transcript via stdin",
                  inv(.summary, .codex)?.contains("| codex exec -") == true)
            // v1→v2 migration: an unset mode with a v1 command must run as .shell (upgrades must not
            // silently kill an existing pipeline); explicit modes always win.
            check("post-process: v1 hook migrates to shell mode",
                  effectivePostProcessMode(rawMode: "", shellCmd: "./x.sh") == .shell
                  && effectivePostProcessMode(rawMode: "", shellCmd: " ") == .off
                  && effectivePostProcessMode(rawMode: "off", shellCmd: "./x.sh") == .off
                  && effectivePostProcessMode(rawMode: "summary", shellCmd: "./x.sh") == .summary)
            // Prompt file: readable file overrides inline; blank/missing file falls back (logged).
            let pfURL = FileManager.default.temporaryDirectory.appendingPathComponent("macrec-prompt-\(UUID().uuidString).md")
            try? "  file prompt\n".write(to: pfURL, atomically: true, encoding: .utf8)
            check("post-process: prompt file overrides inline (trimmed) + fallback",
                  effectiveSummaryPrompt(inline: "inline", filePath: pfURL.path) == "file prompt"
                  && effectiveSummaryPrompt(inline: "inline", filePath: "/nonexistent/p.md") == "inline"
                  && effectiveSummaryPrompt(inline: "inline", filePath: " ") == "inline")
            try? FileManager.default.removeItem(at: pfURL)
            check("post-process: empty prompt falls back to the built-in default",
                  inv(.summary, .claude, prompt: " ")?.contains(defaultSummaryPrompt.prefix(25)) == true)
            check("post-process: summary path derivation (custom dir + tilde)",
                  summaryOutputPath(transcriptPath: "/t/2026-07-07-1000.md", outDir: "") == "/t/2026-07-07-1000-sum.md"
                  && summaryOutputPath(transcriptPath: "/t/2026-07-07-1000-standup.md", outDir: "~/sums")
                     == (("~/sums" as NSString).expandingTildeInPath + "/2026-07/2026-07-07-1000-standup.md")
                  && summaryOutputPath(transcriptPath: "/t/undated-note.md", outDir: "/s")
                     == "/s/undated-note.md")   // no date prefix → no month folder
            // The runner really executes — quoting-hostile path (space + apostrophe) via the shell mode.
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent("macrec hook's \(UUID().uuidString)")
            let markerCmd = postProcessInvocation(mode: .shell, runner: .claude, prompt: "", shellCmd: "touch",
                                                  transcriptPath: marker.path, outDir: "")
            var hookExit: Int32 = -99
            let hookSem = DispatchSemaphore(value: 0)
            runPostProcessCommand(markerCmd ?? "") { code in hookExit = code; hookSem.signal() }
            let hookDone = hookSem.wait(timeout: .now() + 10) == .success
            check("post-process: runner executes with a quoting-safe path",
                  hookDone && hookExit == 0 && FileManager.default.fileExists(atPath: marker.path))
            try? FileManager.default.removeItem(at: marker)
            // Empty command = off: completion must never fire.
            var fired = false
            runPostProcessCommand("   ") { _ in fired = true }
            Thread.sleep(forTimeInterval: 0.2)
            check("post-process: empty command is a no-op", !fired)
            // Settings layout regression (user-reported): a tab taller than the window CLIPPED its rows
            // (Post-process settings were unreachable). Every pane must host its grid in a scroll view,
            // and Post-process must be its own tab. Headless: builds the real form, no window shown.
            let sw = SettingsWindowController(onSave: {})
            let panes = sw.panesForTest
            check("settings: panes built for inspection", !panes.isEmpty)
            check("settings: General pane comes first", panes.first?.title == "General")
            // AUTOMATED UI TEST: lay out every pane at a real size and assert nothing is collapsed
            // or overlapping. This fails the build on visual breakage (the NSBox "card" redesign
            // floated its grids so controls overlapped and shipped destroyed — a structural-only
            // check passed it). Run `macrec settings-snapshot <dir>` to also eyeball the PNGs.
            let layoutIssues = sw.paneLayoutIssues()
            if !layoutIssues.isEmpty { for m in layoutIssues.prefix(8) { print("   layout: \(m)") } }
            check("settings: no pane control is collapsed or overlapping (\(layoutIssues.count) issues)",
                  layoutIssues.isEmpty)
            check("settings: every pane scrolls (rows can never be clipped away)",
                  panes.allSatisfy { p in p.view.subviews.contains { ($0 as? NSScrollView)?.documentView != nil } })
            check("settings: Summaries and Schedule are their own panes",
                  panes.contains { $0.title == "Summaries" } && panes.contains { $0.title == "Schedule" })
            check("settings: Recording split into Recording + Storage panes",
                  panes.contains { $0.title == "Recording" } && panes.contains { $0.title == "Storage" })
            // Grouped row-card structure: every pane renders at least one rounded SectionCard, and
            // no card is empty (a section with no rows would draw a stray hairline box).
            func allCards(in view: NSView) -> [SectionCard] {
                var out: [SectionCard] = []
                if let c = view as? SectionCard { out.append(c) }
                if let sv = view as? NSScrollView, let d = sv.documentView { out += allCards(in: d) }
                for sub in view.subviews { out += allCards(in: sub) }
                return out
            }
            var cardCount = 0
            var everyPaneHasCard = true
            var noEmptyCard = true
            for p in panes {
                let cards = allCards(in: p.view)
                cardCount += cards.count
                if cards.isEmpty { everyPaneHasCard = false }
                for c in cards {
                    // A card wraps a single vertical stack of rows; an empty stack = a bug.
                    let rows = (c.subviews.first as? NSStackView)?.arrangedSubviews ?? []
                    if rows.isEmpty { noEmptyCard = false }
                }
            }
            check("settings: every pane renders at least one section card",
                  cardCount >= panes.count && everyPaneHasCard)
            check("settings: no section card is empty", noEmptyCard)
            // Sidebar search: pane content (not just titles) is the index — "prompt" finds
            // Summaries, junk finds nothing, empty shows everything in order.
            check("settings: sidebar search matches pane content",
                  settingsSearchHits(query: "prompt", index: panes.map { $0.searchText })
                      .contains(panes.firstIndex { $0.title == "Summaries" } ?? -1)
                  && settingsSearchHits(query: "", index: panes.map { $0.searchText }) == Array(panes.indices)
                  && settingsSearchHits(query: "zzxqy", index: panes.map { $0.searchText }).isEmpty
                  && settingsSearchHits(query: "API KEY", index: panes.map { $0.searchText })
                      .contains(panes.firstIndex { $0.title == "Live Captions" } ?? -1))
            // Edit shortcuts in the Settings window (LSUIElement app has no Edit menu — ⌘V into a
            // field once did nothing, user-reported). The window routes these action selectors to
            // the field editor; the mapping is pure and checked here.
            check("settings: ⌘V/⌘C/⌘X/⌘A map to the standard edit actions",
                  standardEditSelector(key: "v", flags: .command) == #selector(NSText.paste(_:))
                  && standardEditSelector(key: "c", flags: .command) == #selector(NSText.copy(_:))
                  && standardEditSelector(key: "x", flags: .command) == #selector(NSText.cut(_:))
                  && standardEditSelector(key: "a", flags: .command) == #selector(NSResponder.selectAll(_:)))
            check("settings: ⌘Z undo, ⌘⇧Z redo, plain V ignored, ⌘⌥V not hijacked",
                  standardEditSelector(key: "z", flags: .command) == Selector(("undo:"))
                  && standardEditSelector(key: "z", flags: [.command, .shift]) == Selector(("redo:"))
                  && standardEditSelector(key: "v", flags: []) == nil
                  && standardEditSelector(key: "v", flags: [.command, .option]) == nil)
            // Schedule pickers (days multi-select + time-range rows) must round-trip through the SAME
            // string prefs the engine parses — seed the UI, read it back, and confirm it parses to the
            // identical RecordSchedule (no meaning lost when we swapped text fields for pickers).
            sw.loadScheduleUI(days: "mon,wed,fri", hours: "10:00-12:00, 13:00-19:00")
            let rtDays = sw.serializeDays(), rtHours = sw.serializeHours()
            check("settings: schedule pickers round-trip to the engine's format",
                  RecordSchedule.parseDays(rtDays) == RecordSchedule.parseDays("mon,wed,fri")
                  && RecordSchedule.parseRanges(rtHours).map { [$0.start, $0.end] }
                     == RecordSchedule.parseRanges("10:00-12:00, 13:00-19:00").map { [$0.start, $0.end] })
            sw.loadScheduleUI(days: "", hours: "")   // empty = every day / all hours
            check("settings: empty schedule serializes empty (every day, all hours)",
                  sw.serializeDays().isEmpty && sw.serializeHours().isEmpty)
            // Nested-scroll passthrough: the pane must still scroll with the pointer over a prompt box.
            // A prompt/calendar box
            // whose content FITS must hand the wheel to the pane; one that OVERFLOWS keeps it to scroll
            // itself. The prompt editor is ~84pt tall — text that fits passes through, long text doesn't.
            check("settings: nested scroll passes wheel to pane when its content fits",
                  nestedScrollPassesThrough(contentHeight: 84, clipHeight: 84)          // exact fit → pass
                  && nestedScrollPassesThrough(contentHeight: 40, clipHeight: 84)       // smaller → pass
                  && !nestedScrollPassesThrough(contentHeight: 400, clipHeight: 84)     // overflow → keep
                  && !nestedScrollPassesThrough(contentHeight: 85, clipHeight: 84))     // just over → keep
            // The embedded editors/lists are actually PassthroughScrollViews in the built tree (prompt,
            // daily-prompt, calendar) — so the fix is wired, not just declared.
            check("settings: embedded editors use the passthrough scroll view",
                  sw.passthroughScrollCountForTest >= 2)
            // Tray Pause/Resume enablement: Pause greys out when nothing is recording (off-hours/idle);
            // Resume stays clickable while paused.
            check("tray: Pause enabled recording; Resume enabled when paused OR schedule-paused; greyed only when truly idle",
                  pauseItemEnabled(paused: false, schedulePaused: false, hasEngine: true)       // recording → can Pause
                  && !pauseItemEnabled(paused: false, schedulePaused: false, hasEngine: false)  // truly idle → greyed
                  && pauseItemEnabled(paused: true, schedulePaused: false, hasEngine: false)    // manual pause → can Resume
                  && pauseItemEnabled(paused: false, schedulePaused: true, hasEngine: false)    // schedule off-hours → can Resume (the fix)
                  && pauseItemEnabled(paused: true, schedulePaused: true, hasEngine: true))
            // Every "Choose…" folder button is bound to a handler the controller implements — guards
            // against a picker wired to nothing / a renamed selector (user: Storage "Choose…" did nothing).
            let chooseWired = sw.chooseButtonsWiredForTest
            check("settings: every Choose… button is wired to a real handler (\(chooseWired.count) found)",
                  chooseWired.count >= 7 && chooseWired.allWired)
            // An NSSwitch carries no title, so its row name has to be attached as an accessibility label
            // or VoiceOver reads an anonymous button where a named setting used to be.
            check("settings: every switch announces its setting name to VoiceOver",
                  sw.unlabeledSwitchesForTest == 0)
            // The footer: "Save" (default) applies in place, "Close" (Esc) leaves. Guards the wiring —
            // a renamed selector here silently turns Save into a dead button.
            let footer = sw.footerButtonsForTest
            check("settings: footer is Close + Save, both wired (Save no longer closes the window)",
                  footer.map(\.title) == ["Close", "Save"]
                  && footer.allSatisfy { b in (b.target as? NSObject)?.responds(to: b.action ?? Selector("")) == true }
                  && footer.last?.keyEquivalent == "\r" && footer.first?.keyEquivalent == "\u{1b}")
            // The overlay's engine picker must never offer an engine that can't run: Deepgram sat in the
            // list with no API key and answered a click with an error line where captions belong.
            // Apple is the floor — switching everything off must not leave an empty picker.
            let noKeys: (LiveEngine) -> Bool = { $0 == .apple || $0 == .whisper }
            check("live: the engine picker offers only engines that are ON and READY (never empty)",
                  selectableLiveEngines(LiveEngine.allCases, ready: noKeys, enabled: { _ in true }) == [.apple, .whisper]
                  && selectableLiveEngines(LiveEngine.allCases, ready: { _ in true },
                                           enabled: { $0 != .apple }) == [.whisper, .deepgram, .openai, .gladia]
                  && selectableLiveEngines(LiveEngine.allCases, ready: noKeys,
                                           enabled: { $0 != .apple && $0 != .whisper }) == [.apple]
                  && selectableLiveEngines(LiveEngine.allCases, ready: { _ in false }, enabled: { _ in false }) == [.apple])
            // The opacity slider fades the BACKGROUND. Fading the window faded the captions with it —
            // at 0.3 the overlay showed nothing at all, which is the one thing it exists to show.
            // Zero is a legal, useful setting — the closed-caption look. Only out-of-range values clamp.
            // Contrast goes BEHIND the glyphs, never into them: a halo smeared them, a stroke thickened
            // them. And only when the backdrop is too faint to carry the contrast itself.
            // A subtitle leads with the TRANSLATION — that is the line you read; the original is a
            // whisper above it. With nothing to translate, the original is the subtitle.
            check("live: a subtitle leads with the translation and demotes the original",
                  subtitleLine(original: "会議を始めましょう。", translated: "회의를 시작합시다.")
                  == ("회의를 시작합시다.", "会議を始めましょう。")
                  && subtitleLine(original: "Let's begin.", translated: nil) == ("Let's begin.", nil)
                  && subtitleLine(original: "Let's begin.", translated: "  ") == ("Let's begin.", nil)
                  && subtitleLine(original: "", translated: "회의") == ("회의", nil))
            // Read at a glance, not squinted at; and a film shows one utterance, not a scrolling wall.
            check("live: a subtitle is larger than the log's body text and shows at most two lines",
                  subtitleFontSize(14) == 20 && subtitleFontSize(9) == 18 && subtitleMaxLines == 2)
            // A transparent LOG keeps an outline so it still reads as a grabbable window; a subtitle must
            // not have one — a rectangle drawn around a film subtitle is what breaks the illusion.
            check("live: the window outline is drawn for the log view and never for a subtitle",
                  captionEdgeVisible(subtitle: false) && !captionEdgeVisible(subtitle: true))
            check("live: captions get a backplate only when the backdrop is too faint to carry contrast",
                  captionTextNeedsBackplate(backdropAlpha: 0.0)
                  && captionTextNeedsBackplate(backdropAlpha: 0.55)
                  && !captionTextNeedsBackplate(backdropAlpha: 0.6)
                  && !captionTextNeedsBackplate(backdropAlpha: 1.0))
            check("live: overlay opacity spans a fully transparent backdrop to a fully opaque one",
                  captionBackdropAlpha(0.0) == 0.0 && captionBackdropAlpha(1.0) == 1.0
                  && captionBackdropAlpha(0.3) == 0.3
                  && captionBackdropAlpha(-1) == 0.0 && captionBackdropAlpha(9.9) == 1.0)
            // Drive the real window: at the slider's low end ONLY the backdrop may be translucent.
            // Window alpha would multiply into every subview, which is exactly how the captions vanished.
            if #available(macOS 26, *) {
                let cw = LiveCaptionWindow(onClose: {}, onReconfigure: {}, onRestyle: {})
                let before = cw.captionAlphasForTest
                cw.setOpacityForTest(0.0)   // the extreme: background gone, captions must not follow it
                let after = cw.captionAlphasForTest
                check("live: at a fully transparent backdrop the window and the captions stay opaque",
                      before.window == 1 && before.text == 1
                      && after.window == 1 && after.text == 1 && after.backdrop == 0.0)
                // The alpha assertion above passed while the overlay rendered as an EMPTY see-through
                // window (a .behindWindow material ignores the view's alpha). Assert the fill exists.
                check("live: the overlay backdrop actually paints, sized to the content, beneath the captions",
                      cw.backdropPaintsForTest)
                // …and nothing paints BEHIND it that the slider can't reach: `.hudWindow` slipped its own
                // full-window material into the theme frame, so the overlay never went fully transparent.
                check("live: no window-chrome material sits behind the backdrop (fully transparent is reachable)",
                      cw.nothingPaintsBehindBackdropForTest)
                // With the background gone the panel loses every edge; the outline must not fade with it,
                // and must not steal the clicks that select text or drag the window.
                let e = cw.edgeSurvivesForTest
                check("live: the outline survives a fully transparent backdrop and never eats the mouse",
                      e.visible && e.ignoresMouse)
                // The picker was built once at window creation: an engine switched off in Settings, or a
                // key just pasted in, stayed invisible until the overlay was closed and reopened.
                let engineChoicesBefore = cw.engineChoicesForTest
                Pref.d.set(["whisper"], forKey: Pref.liveEnginesOn)
                cw.reloadEngineChoices()
                let engineChoicesAfter = cw.engineChoicesForTest
                Pref.d.removeObject(forKey: Pref.liveEnginesOn)
                check("live: reloadEngineChoices re-reads Settings instead of staying frozen at window creation",
                      engineChoicesAfter == [.whisper] && engineChoicesAfter != engineChoicesBefore)
            }
            // The harness must never read the user's real credentials, and every read is an authorization
            // check — an unsigned dev build turns each one into a password prompt.
            _ = Keychain.get("deepgram"); _ = Keychain.get("deepgram"); _ = Keychain.get("openai")
            check("keychain: the test harness never touches the real Keychain",
                  Keychain.disabled && Keychain.readsForTest == 0 && Keychain.get("deepgram") == nil)
            // Asking whether an engine is READY must never ask for a SECRET — that is the authorization
            // prompt. Presence is answered by an attributes-only probe that hands nothing back.
            let secretsBefore = Keychain.secretRequestsForTest
            _ = LiveEngine.deepgram.isReady
            _ = LiveEngine.openai.isReady
            _ = selectableLiveEngines(LiveEngine.allCases, ready: { $0.isReady }, enabled: { $0.isEnabled })
            _ = sw.loadForTest()
            check("keychain: engine readiness and opening Settings request no secrets",
                  Keychain.secretRequestsForTest == secretsBefore
                  && sw.keyFieldsForTest.allSatisfy { $0.isEmpty || $0 == SettingsWindowController.keyMask })
            // MR_KEYCHAIN_ROUNDTRIP=1 drives the REAL Keychain against a throwaway account. It writes,
            // reads back, overwrites and deletes — proving `set` recreates the item (SecItemUpdate leaves
            // the creating process's ACL in place, which is how a credential ends up asking the wrong
            // binary for permission forever). Off by default: the harness must not touch credentials.
            if ProcessInfo.processInfo.environment["MR_KEYCHAIN_ROUNDTRIP"] == "1" {
                let acct = "selftest-roundtrip"
                Keychain.disabled = false
                Keychain.forgetCacheForTest()
                _ = Keychain.set(acct, "")                       // start clean
                let absent = !Keychain.exists(acct) && Keychain.get(acct) == nil
                let wrote = Keychain.set(acct, "first")
                Keychain.forgetCacheForTest()
                let readBack = Keychain.get(acct) == "first" && Keychain.exists(acct)
                let rewrote = Keychain.set(acct, "second")
                Keychain.forgetCacheForTest()
                let reread = Keychain.get(acct) == "second"
                _ = Keychain.set(acct, "")
                Keychain.forgetCacheForTest()
                let gone = !Keychain.exists(acct)
                Keychain.disabled = true
                check("keychain: real round-trip — write, read, recreate on overwrite, delete",
                      absent && wrote && readBack && rewrote && reread && gone)
            }
            // A switch on + no key used to be silent: the engine simply never showed up in the picker.
            check("live: an engine switched on without its credential is reported, not silently dropped",
                  enginesMissingCredentials(LiveEngine.allCases, enabled: { $0 == .deepgram || $0 == .apple },
                                            ready: { $0 == .apple }) == [.deepgram]
                  && enginesMissingCredentials(LiveEngine.allCases, enabled: { _ in true }, ready: { _ in true }).isEmpty
                  && enginesMissingCredentials(LiveEngine.allCases, enabled: { _ in false }, ready: { _ in false }).isEmpty)
            // Indexing allCases picked the wrong engine as soon as one was filtered out of the menu.
            check("live: a popup index maps into the FILTERED list, never into allCases",
                  engineAtPopupIndex(1, choices: [.whisper, .deepgram, .openai, .gladia]) == .deepgram
                  && engineAtPopupIndex(0, choices: [.deepgram]) == .deepgram
                  && engineAtPopupIndex(99, choices: [.apple, .whisper]) == .whisper   // clamped, not a crash
                  && engineAtPopupIndex(0, choices: []) == nil)
            // Turning cloud engines off by default must not silently downgrade someone already on one.
            check("live: an absent ON-list keeps on-device engines and grandfathers the engine already in use",
                  liveEngineEnabled(.apple, storedOn: nil, selectedEngine: nil)
                  && liveEngineEnabled(.whisper, storedOn: nil, selectedEngine: nil)
                  && !liveEngineEnabled(.deepgram, storedOn: nil, selectedEngine: nil)
                  && liveEngineEnabled(.deepgram, storedOn: nil, selectedEngine: "deepgram")   // the upgrade path
                  && liveEngineEnabled(.deepgram, storedOn: ["deepgram"], selectedEngine: nil)
                  && !liveEngineEnabled(.apple, storedOn: ["deepgram"], selectedEngine: "apple"))
            // ⌘V into a Settings field only works because the window is an EditableWindow — an LSUIElement
            // app has no Edit menu, so a plain NSWindow drops the key equivalent on the floor.
            check("settings: the window is an EditableWindow (⌘V/⌘C/⌘X/⌘A reach the field editor)",
                  sw.window is EditableWindow)
            // Restarting the recorder discards the in-progress segment. Save must only do that when a
            // setting the recorder actually reads changed — Return in any text field fires Save now.
            let fpA = engineFingerprint(["voiceMin": "5", "exclude": "com.spotify.client"])
            check("settings: the engine fingerprint changes iff an engine-affecting pref changed",
                  fpA == engineFingerprint(["exclude": "com.spotify.client", "voiceMin": "5"])   // order-independent
                  && fpA != engineFingerprint(["voiceMin": "3", "exclude": "com.spotify.client"])
                  && !SettingsWindowController.engineKeysForTest.contains(Pref.liveEnginesOn)
                  && !SettingsWindowController.engineKeysForTest.contains(Pref.dailyDigestName))
            // Every pref that must make Save restart the recorder. Omitting one means the setting saves
            // and nothing happens — turning the schedule OFF left the engine parked off-hours, because
            // only restartEngine() clears `schedulePaused` and re-baselines the schedule.
            let mustRestart = [Pref.schedEnabled, Pref.schedDays, Pref.schedHours, Pref.segment, Pref.model,
                               Pref.customModel, Pref.lang, Pref.exclude, Pref.txtDir, Pref.audioDir,
                               Pref.systemAudio, Pref.echoReduce, Pref.vad, Pref.keepAudio, Pref.voiceMin,
                               Pref.cal, Pref.calendars, Pref.hintsTerms, Pref.hintsFile, Pref.hintsCalendar]
            check("settings: every recorder-affecting pref (schedule included) forces an engine restart on Save",
                  mustRestart.allSatisfy { SettingsWindowController.engineKeysForTest.contains($0) })
            // System-audio exclusion: match on Core Audio's own process list, so a helper process that
            // plays under its own bundle id is at least VISIBLE (AppKit's app lookup never saw it), and
            // notice when a relaunch (new object id) has made the live tap's frozen exclusion set stale.
            let procs = [AudioProcessInfo(objectID: 501, bundleID: "com.spotify.client"),
                         AudioProcessInfo(objectID: 502, bundleID: "com.spotify.client.helper"),
                         AudioProcessInfo(objectID: 503, bundleID: nil)]
            check("audio: exclusion matches Core Audio's bundle ids; unattributed processes are never excluded",
                  matchExcludedProcesses(procs, excludeBundleIds: ["com.spotify.client"]) == [501]
                  && matchExcludedProcesses(procs, excludeBundleIds: ["com.spotify.client", "com.spotify.client.helper"]) == [501, 502]
                  && matchExcludedProcesses(procs, excludeBundleIds: []).isEmpty)
            check("audio: a relaunched excluded app (new object id) makes the live tap's exclusion stale",
                  tapExclusionIsStale(current: [222], live: [111])          // relaunch — the reported bug
                  && tapExclusionIsStale(current: [111], live: [])          // launched after the tap was built
                  && !tapExclusionIsStale(current: [111, 222], live: [222, 111]))   // same set, any order
            // Sidebar selection is app state, not focus state: the accent pill must survive AppKit
            // clearing isEmphasized when focus moves to a text field (it looked like a random blue blink).
            let sidebarRow = SidebarRowView()
            sidebarRow.isEmphasized = false
            check("settings: sidebar selection stays accent-filled when the table loses focus",
                  sidebarRow.isEmphasized)
            // Click/label/enablement all route through togglePauseShouldResume — test the REAL decision
            // the bug lived in (togglePause resumed only `if paused`, ignoring schedule-pause).
            check("tray: schedule-paused resumes on click (the bug), manual-pause resumes, idle does not",
                  togglePauseShouldResume(paused: false, schedulePaused: true)      // off-hours → Resume (the fix)
                  && togglePauseShouldResume(paused: true, schedulePaused: false)   // manual pause → Resume
                  && !togglePauseShouldResume(paused: false, schedulePaused: false))// recording/idle → Pause
            // Grant item hides only once BOTH capture grants are in (calendar excluded on purpose).
            check("tray: Grant permissions hidden only when audio AND mic granted",
                  captureGrantsSatisfied(audioGranted: true, micGranted: true)
                  && !captureGrantsSatisfied(audioGranted: false, micGranted: true)
                  && !captureGrantsSatisfied(audioGranted: true, micGranted: false))
            // Choose… presents as a SHEET on a visible window (bare runModal opens behind on an
            // .accessory app — the "Choose did nothing" bug); no visible window → activate + runModal.
            check("settings: dir picker uses a sheet iff there is a visible window",
                  dirPickerPresentation(hasVisibleWindow: true) == .sheet
                  && dirPickerPresentation(hasVisibleWindow: false) == .activateAndRunModal)
            // Update-alert Open URL: none for brew; https release URL otherwise; a non-https scheme or a
            // blank/missing API url falls back to the https releases page — never opens an unsafe scheme.
            check("update alert: brew→no button; https htmlURL→that exact link; http/non-https/blank→https releases fallback; unsafe releases→nil",
                  updateAlertOpenURL(installedViaBrew: true, htmlURL: "https://x/y", releasesURL: UpdateChecker.releasesURL) == nil
                  && updateAlertOpenURL(installedViaBrew: false, htmlURL: "https://github.com/ikhoon/macrec/releases/tag/v9", releasesURL: UpdateChecker.releasesURL)?.absoluteString == "https://github.com/ikhoon/macrec/releases/tag/v9"
                  && updateAlertOpenURL(installedViaBrew: false, htmlURL: "http://x/y", releasesURL: UpdateChecker.releasesURL)?.absoluteString == UpdateChecker.releasesURL
                  && updateAlertOpenURL(installedViaBrew: false, htmlURL: "javascript:alert(1)", releasesURL: UpdateChecker.releasesURL)?.absoluteString == UpdateChecker.releasesURL
                  && updateAlertOpenURL(installedViaBrew: false, htmlURL: "", releasesURL: UpdateChecker.releasesURL)?.absoluteString == UpdateChecker.releasesURL
                  && updateAlertOpenURL(installedViaBrew: false, htmlURL: nil, releasesURL: "file:///etc/passwd") == nil)
            // The menu-bar brand mark actually draws in every state (not an all-transparent image — the
            // "structurally valid but visually destroyed" class of bug). LOOK via `macrec icon-snapshot`.
            check("tray icon: brand mark renders content (recording, recording+voice, paused)",
                  brandMarkHasContent(recording: true, voice: true)
                  && brandMarkHasContent(recording: true, voice: false)
                  && brandMarkHasContent(recording: false, voice: false))
            // Short-blip filter: no overlapping meeting + under 3 min of speech → no file (user rule).
            check("keep transcript: meeting always kept; no meeting needs ≥3 min speech",
                  shouldKeepTranscript(hasMeeting: true, speechSeconds: 5)
                  && shouldKeepTranscript(hasMeeting: false, speechSeconds: 180)
                  && shouldKeepTranscript(hasMeeting: false, speechSeconds: 240)
                  && !shouldKeepTranscript(hasMeeting: false, speechSeconds: 179)
                  && !shouldKeepTranscript(hasMeeting: false, speechSeconds: 0))
            // Summaries Mode is a real TAB — it SHOWS only the selected mode's sections (not readonly
            // greying). Switch each mode and confirm only that group is visible.
            sw.setPPModeForTest("summary")
            check("summaries tab: Automatic summary shown, Custom command + off hidden",
                  sw.ppGroupVisibleForTest("pp.summary")
                  && !sw.ppGroupVisibleForTest("pp.shell") && !sw.ppGroupVisibleForTest("pp.off"))
            sw.setPPModeForTest("shell")
            check("summaries tab: Custom command shown, Automatic summary hidden",
                  sw.ppGroupVisibleForTest("pp.shell") && !sw.ppGroupVisibleForTest("pp.summary"))
            sw.setPPModeForTest("off")
            check("summaries tab: off note shown, both mode sections hidden",
                  sw.ppGroupVisibleForTest("pp.off")
                  && !sw.ppGroupVisibleForTest("pp.summary") && !sw.ppGroupVisibleForTest("pp.shell"))
            // Transcription hints: parsing (comma/newline/#comment), case-insensitive dedupe, cap.
            check("hints: parse comma/newline + comments",
                  parseHintTerms("Kubernetes, gRPC\n# note\n김철수\n\n") == ["Kubernetes", "gRPC", "김철수"])
            check("hints: comment runs to end of line (commas inside don't leak) + inline comment",
                  parseHintTerms("# old, stuff\nAlpha # trailing, note\nBeta") == ["Alpha", "Beta"])
            // Transcript-level echo suppression — cases lifted from the user's real screenshot.
            check("echo text: exact copy suppressed",
                  isLikelyEcho(mine: "Over time, I got better at finding it.",
                               theirs: "Over time, I got better at finding it."))
            check("echo text: garbled copy suppressed",   // a garbled mic copy shares ≥80% of its tokens
                  isLikelyEcho(mine: "I wasn't very very find the award in the beginning, but I",
                               theirs: "I wasn't very good at finding north in the beginning, but I additioned a fair amount, and so my dad kept asking me, which way is north?"))
            check("echo text: unrelated line kept",
                  !isLikelyEcho(mine: "That's like a one of my life.",
                                theirs: "Not just by how far my life has come since then, but..."))
            check("echo text: short reply never eaten",
                  !isLikelyEcho(mine: "Yes.", theirs: "Yes.") && !isLikelyEcho(mine: "네 네 네", theirs: "네 네 네 알겠습니다"))
            let echoMerged: [(start: Double, who: String, text: String)] = [
                (10, "상대", "Over time, I got better at finding it."),
                (12, "나", "Over time, I got better at finding it."),     // echo → dropped
                (14, "나", "완전히 다른 내 얘기를 길게 하고 있어요"),         // genuine → kept
                (40, "나", "Over time, I got better at finding it."),     // outside ±8 s → kept
            ]
            let echoOut = suppressEchoLines(echoMerged, mine: "나")
            check("echo text: merged transcript drops only the in-window copy",
                  echoOut.map { $0.start } == [10, 14, 40])
            // Recording schedule: day parsing (ranges incl. wrap), hour ranges (lunch gap), isActive.
            check("schedule: day parsing",
                  RecordSchedule.parseDays("mon-fri") == [2, 3, 4, 5, 6]
                  && RecordSchedule.parseDays("MON, wed,fri") == [2, 4, 6]
                  && RecordSchedule.parseDays("sat-mon") == [7, 1, 2]      // wraps the week
                  && RecordSchedule.parseDays("nope, mon") == [2]          // junk skipped
                  && RecordSchedule.parseDays("") == [])
            check("schedule: hour-range parsing",
                  RecordSchedule.parseRanges("10:00-12:00, 13:00-19:00").map { [$0.start, $0.end] } == [[600, 720], [780, 1140]]
                  && RecordSchedule.parseRanges("23:00-24:00").map { [$0.start, $0.end] } == [[1380, 1440]]
                  && RecordSchedule.parseRanges("garbage, 25:00-26:00, 10:00-10:00").isEmpty)   // invalid/empty skipped
            check("schedule: pasted dashes + overnight wrap",
                  RecordSchedule.parseRanges("10:00–12:00").map { [$0.start, $0.end] } == [[600, 720]]      // en dash
                  && RecordSchedule.parseRanges("13:00~19:00").map { [$0.start, $0.end] } == [[780, 1140]]  // tilde range
                  && RecordSchedule.parseDays("mon–fri") == [2, 3, 4, 5, 6]
                  && RecordSchedule.parseRanges("22:00-06:00").map { [$0.start, $0.end] } == [[1320, 1440], [0, 360]])
            check("schedule: invalid input detected (never silently records 24/7)",
                  !RecordSchedule.hoursValid("10am-7pm") && !RecordSchedule.hoursValid("10:00-10:00")
                  && RecordSchedule.hoursValid("10:00–12:00, 13:00~19:00") && RecordSchedule.hoursValid("")
                  && !RecordSchedule.daysValid("mon-frii") && RecordSchedule.daysValid("mon–fri") && RecordSchedule.daysValid(""))
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
            func schedDate(_ s: String) -> Date {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = utc.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"; return f.date(from: s)!
            }
            let sched = RecordSchedule.from(enabled: true, days: "mon-fri", hours: "10:00-12:00, 13:00-19:00")
            check("schedule: mon-fri work hours minus lunch",
                  sched.isActive(at: schedDate("2026-07-06 10:00"), calendar: utc)      // Mon 10:00 → on
                  && !sched.isActive(at: schedDate("2026-07-06 12:30"), calendar: utc)  // lunch gap → off
                  && sched.isActive(at: schedDate("2026-07-06 18:59"), calendar: utc)
                  && !sched.isActive(at: schedDate("2026-07-06 19:00"), calendar: utc)  // end is exclusive
                  && !sched.isActive(at: schedDate("2026-07-05 11:00"), calendar: utc)) // Sunday → off
            check("schedule: disabled = always on; half-filled form never stops recording",
                  RecordSchedule.from(enabled: false, days: "", hours: "").isActive(at: schedDate("2026-07-05 03:00"), calendar: utc)
                  && RecordSchedule.from(enabled: true, days: "mon-fri", hours: "").isActive(at: schedDate("2026-07-06 03:00"), calendar: utc)
                  && RecordSchedule.from(enabled: true, days: "", hours: "10:00-11:00").isActive(at: schedDate("2026-07-05 10:30"), calendar: utc))
            // Menu hover: a view-backed item gets NO native highlight — MenuHoverView must provide
            // the selection pill + notify the label restyle, and reset when the menu reopens.
            do {
                let hv = MenuHoverView(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
                var hoverStates: [Bool] = []
                hv.onHover = { hoverStates.append($0) }
                let initiallyOff = !hv.highlightVisibleForTest
                hv.setHover(true)
                let litAndNotified = hv.highlightVisibleForTest && hoverStates == [true]
                hv.setHover(false)
                let offAgain = !hv.highlightVisibleForTest && hoverStates == [true, false]
                check("menu hover: pill shows on hover, hides after, restyle notified",
                      initiallyOff && litAndNotified && offAgain)
                check("menu hover: tracking area installed (mouse enter/exit will arrive)",
                      hv.trackingReadyForTest)
            }
            // Transcribe-now push: terminal statuses notify (the menu may be closed by then),
            // transient ones keep waiting — a dangling flag would mis-attribute the NEXT hourly segment.
            // Post-processing was invisible: it ran, left nothing behind, and the app read as broken.
            let stamp = schedDate("2026-07-07 12:03")
            let hm: (Date) -> String = { d in let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
                                             f.timeZone = utc.timeZone; f.dateFormat = "HH:mm"; return f.string(from: d) }
            check("tray: the summary row names the state, the file and when it happened",
                  summaryMenuTitle(.off, hm: hm) == "Summaries: off"
                  && summaryMenuTitle(.idle, hm: hm) == "Summary: after the next transcript"
                  && summaryMenuTitle(.running("a.md"), hm: hm) == "Summary: running… a.md"
                  && summaryMenuTitle(.done("a.md", stamp), hm: hm) == "Summary: a.md · 12:03"
                  && summaryMenuTitle(.failed("a.md", stamp, reason: "Not logged in"), hm: hm)
                     == "Summary FAILED: a.md · 12:03")
            // A row that is clickable must DO something. Enablement and the click read one decision, so
            // they cannot disagree — clicking a failure explains it, never nothing.
            check("tray: the summary row's click always has an outcome, and a failure explains itself",
                  summaryRowAction(.failed("a.md", stamp, reason: "Not logged in · Please run /login"), lastOutput: nil)
                  == .explain("a.md", "Not logged in · Please run /login")
                  && summaryRowAction(.failed("a.md", stamp, reason: nil), lastOutput: "/s/old.md")
                  == .explain("a.md", nil)                        // failure wins over a stale old file
                  && summaryRowAction(.done("a.md", stamp), lastOutput: "/s/a.md") == .reveal("/s/a.md")
                  && summaryRowAction(.idle, lastOutput: nil) == .none
                  && summaryRowAction(.off, lastOutput: "/s/a.md") == .none)
            // The runner writes STDOUT to `<out>.partial` and only then promotes it, so its error message
            // lands INSIDE that file, never on stderr. `claude` exiting 1 with "Not logged in" left only
            // "exit 1" in the log, and the orphaned .partial piled up in the notes vault for days.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("macrec-reap-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let outPath = tmp.appendingPathComponent("2026-07-10-1030-standup.md").path
            try? "Not logged in · Please run /login\n".write(toFile: outPath + ".partial", atomically: true, encoding: .utf8)
            let reason = reapFailedPostProcess(outPath: outPath)
            let orphanGone = !FileManager.default.fileExists(atPath: outPath + ".partial")
            let noReason = reapFailedPostProcess(outPath: tmp.appendingPathComponent("absent.md").path)
            try? FileManager.default.removeItem(at: tmp)
            check("summary: a failed runner's reason is read back from its .partial, which is then removed",
                  reason == "Not logged in · Please run /login" && orphanGone && noReason == nil)
            check("tray: the digest row says off, due, or already written today",
                  digestMenuTitle(enabled: false, dueTime: "20:00", lastRun: "", today: "2026-07-07")
                  == "Daily digest: off"
                  && digestMenuTitle(enabled: true, dueTime: "20:00", lastRun: "", today: "2026-07-07")
                  == "Daily digest: due at 20:00"
                  && digestMenuTitle(enabled: true, dueTime: "20:00", lastRun: "2026-07-07", today: "2026-07-07")
                  == "Daily digest: written today"
                  && digestMenuTitle(enabled: true, dueTime: "20:00", lastRun: "2026-07-06", today: "2026-07-07")
                  == "Daily digest: due at 20:00")
            // A summary that ran must be reachable: the row is only clickable once it produced a file.
            SummaryStatus.shared.resetForTest()
            let noOutput = SummaryStatus.shared.lastOutput == nil && SummaryStatus.shared.current == .idle
            SummaryStatus.shared.started("a.md")
            let running = SummaryStatus.shared.current == .running("a.md")
            SummaryStatus.shared.finished("a.md", at: stamp, output: "/s/a.md")
            check("tray: summary status tracks running → done and remembers the file it wrote",
                  noOutput && running
                  && SummaryStatus.shared.current == .done("a.md", stamp)
                  && SummaryStatus.shared.lastOutput == "/s/a.md")
            SummaryStatus.shared.failed("b.md", at: stamp, reason: "boom")
            check("tray: a failure carries its reason all the way to the row's click",
                  summaryRowAction(SummaryStatus.shared.current, lastOutput: SummaryStatus.shared.lastOutput)
                  == .explain("b.md", "boom"))
            SummaryStatus.shared.resetForTest()
            // The row is a control, and a control wired to nothing looks perfect until you click it.
            check("tray: the summary row's reveal action is implemented",
                  AppController.instancesRespond(to: Selector(("revealLastSummary"))))
            check("flush push: terminal statuses classified, transient ones wait",
                  flushOutcome(for: "Saved: 2026-07-05-2100-2130.md")! == ("Transcript ready", "2026-07-05-2100-2130.md")
                  && flushOutcome(for: "No speech — discarded") != nil
                  && flushOutcome(for: "No speech — skipped") != nil
                  && flushOutcome(for: "Downloading model — transcription deferred") != nil
                  && flushOutcome(for: "Transcription failed") != nil
                  // Every status `process` can END on must classify, or "Transcribe now" hangs on its
                  // spinner and the still-armed flag steals the next segment's notification.
                  && flushOutcome(for: "No meeting · short — skipped") != nil
                  && flushOutcome(for: "Transcribing…") == nil
                  && flushOutcome(for: "Recording · mic + system audio") == nil
                  && flushOutcome(for: "Paused (locked/asleep)") == nil)
            check("flush push: spinner holds to a visible minimum, never negative",
                  abs(spinnerHold(elapsed: 0.3) - 0.7) < 1e-9
                  && spinnerHold(elapsed: 1.0) == 0
                  && spinnerHold(elapsed: 45) == 0
                  && spinnerHold(elapsed: 0) == 1.0)
            // L3 daily digest: due-logic (deadline + once-a-day marker = sleep catch-up), input
            // preference (summary over transcript, matched by basename), path fallbacks, invocation.
            check("digest: due after deadline, once per day, junk time never fires",
                  dailyDigestDue(now: schedDate("2026-07-07 20:01"), time: "20:00", lastRun: "", calendar: utc)
                  && !dailyDigestDue(now: schedDate("2026-07-07 19:59"), time: "20:00", lastRun: "", calendar: utc)
                  && !dailyDigestDue(now: schedDate("2026-07-07 20:01"), time: "20:00", lastRun: "2026-07-07", calendar: utc)
                  && dailyDigestDue(now: schedDate("2026-07-08 23:00"), time: "20:00", lastRun: "2026-07-07", calendar: utc)
                  && !dailyDigestDue(now: schedDate("2026-07-07 20:01"), time: "25:99", lastRun: "", calendar: utc))
            check("digest: inputs prefer the summary, fall back to the transcript, day-filtered + sorted",
                  dailyDigestInputs(day: "2026-07-07",
                                    transcripts: ["/t/2026-07-07-1400.md", "/t/2026-07-06-1000.md", "/t/2026-07-07-1000-standup.md"],
                                    summaries: ["/s/2026-07-07-1000-standup.md"])
                  == ["/s/2026-07-07-1000-standup.md", "/t/2026-07-07-1400.md"])
            // A digest lands in the SAME month folder as the day's notes, and `2026-07-07.md` carries the
            // very day-prefix the input filter matches — without the exclusion it would feed itself its
            // own previous output. Compared by standardized path (`/t/./x.md` is the same file as `/t/x.md`).
            check("digest: the digest we're about to write is never one of its own inputs",
                  dailyDigestInputs(day: "2026-07-07",
                                    transcripts: ["/t/2026-07/./2026-07-07.md", "/t/2026-07/2026-07-07-1000-standup.md"],
                                    summaries: ["/t/2026-07/2026-07-07.md"],
                                    excluding: "/t/2026-07/2026-07-07.md")
                  == ["/t/2026-07/2026-07-07-1000-standup.md"])
            // The name is the user's to choose: default is a bare date, tokens expand, a missing
            // extension is added, and a blank or `/`-bearing template can't produce a nameless file
            // or escape the month folder.
            check("digest: file name comes from a user template, defaults to {date}.md",
                  dailyDigestFileName(day: "2026-07-07") == "2026-07-07.md"
                  && dailyDigestFileName(day: "2026-07-07", template: "") == "2026-07-07.md"
                  && dailyDigestFileName(day: "2026-07-07", template: "{date}-daily") == "2026-07-07-daily.md"
                  && dailyDigestFileName(day: "2026-07-07", template: ".md") == "2026-07-07.md"
                  && dailyDigestFileName(day: "2026-07-07", template: "../{date}.md") == "..-2026-07-07.md")
            // A template with no {date} resolved to one path for the whole month, and the digest is
            // promoted with `mv` — every day silently overwrote the day before.
            check("digest: a name without {date} still gets the day, so days can't overwrite each other",
                  dailyDigestFileName(day: "2026-07-07", template: "notes.md") == "2026-07-07-notes.md"
                  && dailyDigestFileName(day: "2026-07-07", template: "digest-{month}.md") == "2026-07-07-digest-2026-07.md")
            // A summary saved next to its transcript is `<base>-sum.md`; keying on the raw basename meant
            // the digest never found it and quietly fed on the raw transcript instead.
            check("digest: a `-sum` summary next to its transcript is matched to that transcript",
                  dailyDigestInputs(day: "2026-07-07",
                                    transcripts: ["/t/2026-07-07-1000-standup.md"],
                                    summaries: ["/t/2026-07-07-1000-standup-sum.md"])
                  == ["/t/2026-07-07-1000-standup-sum.md"])
            // No `Daily/` tree any more — we only ever create the month folder under the dir the user
            // picked; choosing where that folder lives is the user's job, not ours.
            check("digest: output path — <picked dir>/YYYY-MM/<name>, no injected Daily folder",
                  dailyDigestOutputPath(day: "2026-07-07", outDir: "/d", summaryOutDir: "/r/Summaries", transcriptsDir: "/r/Transcripts")
                  == "/d/2026-07/2026-07-07.md"
                  && dailyDigestOutputPath(day: "2026-07-07", outDir: "", summaryOutDir: "/r/Summaries", transcriptsDir: "/r/Transcripts")
                  == "/r/Summaries/2026-07/2026-07-07.md"
                  && dailyDigestOutputPath(day: "2026-07-07", outDir: "", summaryOutDir: "", transcriptsDir: "/r/Transcripts")
                  == "/r/Transcripts/2026-07/2026-07-07.md"
                  && dailyDigestOutputPath(day: "2026-07-07", outDir: "/d", summaryOutDir: "", transcriptsDir: "/r/T",
                                           nameTemplate: "{date}-daily.md") == "/d/2026-07/2026-07-07-daily.md")
            check("digest: invocation cats inputs into the runner with atomic promote",
                  dailyDigestInvocation(runner: .claude, prompt: "P", inputs: ["/s/a.md", "/s/b's.md"], outPath: "/d/2026-07/x.md")
                  == "mkdir -p '/d/2026-07' && cat '/s/a.md' '/s/b'\\''s.md' | claude -p 'P' "
                   + "> '/d/2026-07/x.md.partial' && mv '/d/2026-07/x.md.partial' '/d/2026-07/x.md'"
                  && dailyDigestInvocation(runner: .claude, prompt: "P", inputs: [], outPath: "/d/x.md") == nil)
            // Tail-scheduler decision — both timing regressions ("not real-time" = timer wait,
            // "second line slow" = firing while another request was in flight) lived here.
            check("live: tail fire decision (one in flight, only when moved, never after final)",
                  shouldFireTailTranslation(tail: "새 꼬리", lastSent: "", inFlight: false, final: false)
                  && !shouldFireTailTranslation(tail: "같음", lastSent: "같음", inFlight: false, final: false)
                  && !shouldFireTailTranslation(tail: "새 꼬리", lastSent: "옛", inFlight: true, final: false)
                  && !shouldFireTailTranslation(tail: "새 꼬리", lastSent: "", inFlight: false, final: true)
                  && !shouldFireTailTranslation(tail: "", lastSent: "옛", inFlight: false, final: false))
            // Rendering must stay IN ORDER while sentence translations land async: part 2 landing
            // before part 1 must NOT display until part 1 arrives; the volatile tail renders last.
            if #available(macOS 26, *) {
                var cl = LiveCaptions.CapLine(speaker: "나", text: "a. b. c", final: false, time: Date())
                cl.transParts = [nil, "TWO"]
                cl.transTail = "tail"
                let outOfOrderHidden = cl.translated == "tail"        // part 2 waits for part 1
                cl.transParts = ["ONE", "TWO"]
                let ordered = cl.translated == "ONE TWO tail"
                cl.transTail = nil
                let frozen = cl.translated == "ONE TWO"
                check("live: translation renders in order (late part 1 gates part 2; tail last)",
                      outOfOrderHidden && ordered && frozen)
            }
            // Live translation streams per COMPLETED sentence — the splitter must not fire on
            // decimals or on a trailing period that hasn't been confirmed by a following space.
            check("live: sentence splitter (decimals safe, tail waits, hard punct immediate)",
                  completeSentences("안녕하세요. 오늘 회의는") == ["안녕하세요."]
                  && completeSentences("3.5 퍼센트입니다. 다음 안건은") == ["3.5 퍼센트입니다."]
                  && completeSentences("됐나요? 정말요! 네.") == ["됐나요?", "정말요!"]
                  && completeSentences("아직 문장이 안 끝났") == []
                  && completeSentences("First point. Second point here") == ["First point."])
            // Update check: dotted-numeric compare (string compare says "0.10" < "0.9").
            check("update: version compare handles multi-digit, v-prefix, unequal lengths",
                  isNewerVersion("v0.6.0", than: "0.5.0")
                  && isNewerVersion("0.10.0", than: "0.9.9")
                  && isNewerVersion("1.0", than: "0.99.99")
                  && !isNewerVersion("v0.5.0", than: "0.5.0")
                  && !isNewerVersion("0.5", than: "0.5.0")
                  && !isNewerVersion("0.4.9", than: "0.5.0"))
            // File naming: start time only (the end time lived in the name briefly — clutter).
            check("naming: transcript base is the start time only",
                  transcriptBaseName(start: schedDate("2026-07-05 21:00"), timeZone: utc.timeZone) == "2026-07-05-2100"
                  && transcriptBaseName(start: schedDate("2026-07-05 23:50"), timeZone: utc.timeZone) == "2026-07-05-2350")
            // A mapped meeting stamps the transcript with the MEETING's start, clamped to the recorded
            // window: a 21:10 meeting inside the 21:00 rotation slice files as 21:10, while the second
            // hour of a 20:30 meeting still files as 21:00 — otherwise both slices of one long meeting
            // would claim 20:30, collapse onto the same name, and the later one would overwrite the first.
            let segA = schedDate("2026-07-05 21:00"), segAEnd = schedDate("2026-07-05 22:00")
            check("naming: a mapped calendar event stamps its own start, clamped to the recorded window",
                  transcriptStart(segStart: segA, segEnd: segAEnd, eventStart: nil) == segA
                  && transcriptStart(segStart: segA, segEnd: segAEnd,
                                     eventStart: schedDate("2026-07-05 21:10")) == schedDate("2026-07-05 21:10")
                  && transcriptStart(segStart: segA, segEnd: segAEnd,
                                     eventStart: schedDate("2026-07-05 20:30")) == segA          // continuation slice
                  && transcriptStart(segStart: segA, segEnd: segAEnd,
                                     eventStart: schedDate("2026-07-05 22:30")) == segAEnd       // matched on the +60s window
                  && transcriptBaseName(start: transcriptStart(segStart: segA, segEnd: segAEnd,
                                                               eventStart: schedDate("2026-07-05 21:10")),
                                        timeZone: utc.timeZone) == "2026-07-05-2110")
            // Dead-mic detection — the jack-input incident: hours of segments "voiced" by clicks
            // (energy-gate trips) while containing zero speech-length runs, all discarded silently.
            check("mic guard: speech-run accounting (clicks never qualify, speech does)",
                  speechlikeFrames(Array(repeating: 0.5, count: 799) + [0.0]) == 0        // 49.9 ms — just under
                  && speechlikeFrames(Array(repeating: 0.5, count: 800)) == 800           // 50 ms run qualifies fully
                  && speechlikeFrames(Array(repeating: 0.5, count: 1200)) == 1200
                  && speechlikeFrames((0..<8000).map { $0 % 100 < 8 ? 0.5 : 0.0 }) == 0   // click train
                  && speechlikeFrames(Array(repeating: 0.5, count: 900) + Array(repeating: 0.0, count: 100)
                                      + Array(repeating: 0.5, count: 900)) == 1800)       // two syllables
            check("mic guard: dead-input verdict (energy without speech runs)",
                  micLooksDead(voiced: 44.1, speech: 0.1)      // the real incident segment
                  && !micLooksDead(voiced: 22.4, speech: 8.0)  // real speech
                  && !micLooksDead(voiced: 3.0, speech: 0.0)   // quiet hour — no verdict
                  && !micLooksDead(voiced: 6.0, speech: 0.6))  // borderline but speech present
            // Hallucination scrubbing — the exact failure classes from our junk transcripts:
            // a broadcast hour where one sentence repeated for 15 minutes, YouTube-outro
            // boilerplate on quiet rooms, "oh oh oh…" degeneration. Real speech must survive.
            check("scrub: boilerplate + within-line loop dropped, real speech kept",
                  Transcriber.isHallucinatedLine("ご視聴ありがとうございました")
                  && Transcriber.isHallucinatedLine("시청해 주셔서 감사합니다.")
                  && Transcriber.isHallucinatedLine("Thanks for watching!")
                  && Transcriber.isHallucinatedLine(Array(repeating: "oh,", count: 28).joined(separator: " "))
                  && !Transcriber.isHallucinatedLine("이번 스프린트에 배포 파이프라인 마이그레이션을 마무리하기로 했습니다.")
                  && !Transcriber.isHallucinatedLine("네, 네. 알겠습니다.")
                  && !Transcriber.isHallucinatedLine("Let's start with the deployment status update."))
            // Review-verified false-positive victims that MUST survive: short real repetition
            // (backchannels, chants) under the 80-byte gate; sentences that merely MENTION
            // boilerplate phrases (anchored match, not contains).
            check("scrub: real Korean repetition + boilerplate mentions survive",
                  !Transcriber.isHallucinatedLine("네, 네, 네, 네, 네, 네, 네, 네, 네.")
                  && !Transcriber.isHallucinatedLine("파이팅 파이팅 파이팅 파이팅 파이팅")
                  && !Transcriber.isHallucinatedLine("Thank you for watching the demo, any questions before we move on?")
                  && !Transcriber.isHallucinatedLine("구독과 좋아요 버튼 위치를 바꾸는 A/B 테스트를 해 보죠."))
            check("scrub: dominant 4-gram loop detected, varied prose passes",
                  Transcriber.maxNgramShare(Array(repeating: "you should be able to get the ball", count: 8).joined(separator: " ")) > 0.1
                  && Transcriber.maxNgramShare("the quick brown fox jumps over the lazy dog while the calm river flows past the quiet village near the tall mountain") <= 0.06)
            do {
                // The observed 15-minute loop: one sentence every ~3 s for 240 lines. Collapses to
                // its first occurrence; identical REAL repeats far apart (>30 s) are both kept.
                let loop = (0..<240).map { (10.0 + Double($0) * 3, "You should be able to get the ball from the right side.") }
                let lines = [(5.0, "회의 시작하겠습니다.")] + loop + [(950.0, "다음 주제로 넘어가죠.")]
                let (kept, dropped) = Transcriber.scrubLines(lines)
                check("scrub: 240-line repetition loop collapses to one, neighbors survive",
                      kept.map { $0.1 } == ["회의 시작하겠습니다.",
                                            "You should be able to get the ball from the right side.",
                                            "다음 주제로 넘어가죠."] && dropped == 239)
                let farApart = [(10.0, "네."), (500.0, "네.")]
                check("scrub: identical backchannels far apart both survive",
                      Transcriber.scrubLines(farApart).kept.count == 2)
            }
            check("scrub: compression ratio separates loops from prose",
                  Transcriber.compressionRatio(String(repeating: "구독과 좋아요 부탁드립니다 ", count: 12)) > 2.4
                  && Transcriber.compressionRatio("오늘 논의된 내용은 세 가지였고 각각 담당자가 다음 주까지 정리하기로 했습니다.") < 2.4)
            // Audio archive tiers: raw → compressed → deleted, with 0 disabling a stage.
            check("audio tiers: raw → compressed → deleted (0 = never/forever)",
                  AudioArchivePolicy(rawDays: 7, totalDays: 90).tier(ageDays: 3) == .raw
                  && AudioArchivePolicy(rawDays: 7, totalDays: 90).tier(ageDays: 7) == .compressed
                  && AudioArchivePolicy(rawDays: 7, totalDays: 90).tier(ageDays: 90) == .deleted
                  && AudioArchivePolicy(rawDays: 0, totalDays: 90).tier(ageDays: 60) == .raw          // never compress
                  && AudioArchivePolicy(rawDays: 7, totalDays: 0).tier(ageDays: 400) == .compressed   // keep forever
                  && AudioArchivePolicy(rawDays: 30, totalDays: 14).tier(ageDays: 20) == .deleted)    // delete wins
            check("audio tiers: retention combo text parsing",
                  AudioArchivePolicy.parseRetentionDays("90 days") == 90
                  && AudioArchivePolicy.parseRetentionDays("1 year") == 365
                  && AudioArchivePolicy.parseRetentionDays("6 months") == 180
                  && AudioArchivePolicy.parseRetentionDays("2 weeks") == 14
                  && AudioArchivePolicy.parseRetentionDays("45") == 45
                  && AudioArchivePolicy.parseRetentionDays("Unlimited") == 0
                  && AudioArchivePolicy.parseRetentionDays("Don't compress") == 0
                  && AudioArchivePolicy.parseRetentionDays("soon") == nil
                  && AudioArchivePolicy.parseRetentionDays("") == nil
                  && AudioArchivePolicy.parseRetentionDays("9223372036854775807 years") == nil)  // typed live: red, not a trap
            check("audio tiers: titles round-trip through the parser",
                  [7, 90, 180, 365, 730, 0].allSatisfy {
                      AudioArchivePolicy.parseRetentionDays(AudioArchivePolicy.retentionTitle($0)) == $0
                  })
            // Real afconvert round-trip — would have caught 64 kbps being rejected ('!dat') at 16 kHz
            // mono. Also proves the retention clock survives archiving (mdate carried over).
            do {
                let fm = FileManager.default
                let dir = fm.temporaryDirectory.appendingPathComponent("macrec-selftest-\(ProcessInfo.processInfo.processIdentifier)")
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let wav = dir.appendingPathComponent("tone.wav"), m4a = dir.appendingPathComponent("tone.m4a")
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0,
                                               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]
                if let file = try? AVAudioFile(forWriting: wav, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false),
                   let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16000) {
                    buf.frameLength = 16000
                    for i in 0..<16000 { buf.floatChannelData![0][i] = sinf(Float(i) * 0.1) * 0.3 }
                    try? file.write(from: buf)
                }
                let past = Date(timeIntervalSinceNow: -86400 * 10)
                try? fm.setAttributes([.modificationDate: past], ofItemAtPath: wav.path)
                let ok = AudioArchiver.compress(wav, to: m4a)
                let size = (try? fm.attributesOfItem(atPath: m4a.path))?[.size] as? Int ?? 0
                let mdate = (try? m4a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                check("audio tiers: afconvert AAC round-trip keeps the retention clock",
                      ok && size > 0 && abs(mdate.timeIntervalSince(past)) < 2)
                try? fm.removeItem(at: dir)
            }
            // nextBoundary anchors the manual-override expiry: a wall-clock timestamp, so sleeping
            // across boundaries still expires it. Fri 20:00 → next flip is MONDAY 10:00 (skips the weekend).
            check("schedule: next boundary (lunch edge, weekend skip, never-flips → nil)",
                  sched.nextBoundary(after: schedDate("2026-07-06 11:00"), calendar: utc) == schedDate("2026-07-06 12:00")
                  && sched.nextBoundary(after: schedDate("2026-07-06 12:30"), calendar: utc) == schedDate("2026-07-06 13:00")
                  && sched.nextBoundary(after: schedDate("2026-07-10 20:00"), calendar: utc) == schedDate("2026-07-13 10:00")
                  && RecordSchedule.from(enabled: false, days: "mon-fri", hours: "").nextBoundary(after: schedDate("2026-07-06 11:00"), calendar: utc) == nil
                  && RecordSchedule.from(enabled: true, days: "", hours: "").nextBoundary(after: schedDate("2026-07-06 11:00"), calendar: utc) == nil)
            check("hints: dedupe (case-insensitive) + priority order",
                  mergeHintTerms(direct: ["Alpha", "Beta"], file: ["alpha", "Gamma"], event: ["Beta", "김철수"])
                  == ["Alpha", "Beta", "Gamma", "김철수"])
            check("hints: cap respected",
                  mergeHintTerms(direct: (1...100).map(String.init), file: [], event: []).count == 60)
            // Live pass-through: Deepgram gets per-term `keywords` boosts; OpenAI gets a transcription prompt.
            let dgURL = DeepgramLiveTranscriber.listenURL(lang: "ko", keywords: ["Kubernetes", "김철수"]).absoluteString
            check("hints: deepgram keywords in the listen URL",
                  dgURL.contains("keywords=Kubernetes") && dgURL.contains("keywords=") && dgURL.contains("language=ko"))
            let oaCfg = OpenAILiveTranscriber.sessionConfig(lang: "ko", hints: "Kubernetes, 김철수")
            let oaTr = (oaCfg["session"] as? [String: Any])?["input_audio_transcription"] as? [String: Any]
            let oaCfgNoHints = OpenAILiveTranscriber.sessionConfig(lang: "ko", hints: "")
            let oaTrNo = (oaCfgNoHints["session"] as? [String: Any])?["input_audio_transcription"] as? [String: Any]
            check("hints: openai transcription prompt set only when non-empty",
                  (oaTr?["prompt"] as? String) == "Kubernetes, 김철수" && oaTrNo?["prompt"] == nil)
            // Gladia engine: REST-init body (language + vocabulary only when present) + transcript parsing.
            let glBody = GladiaLiveTranscriber.initBody(lang: "ko", vocabulary: ["Kubernetes"])
            let glLangs = (glBody["language_config"] as? [String: Any])?["languages"] as? [String]
            let glVocab = (((glBody["realtime_processing"] as? [String: Any])?["custom_vocabulary_config"]
                            as? [String: Any])?["vocabulary"]) as? [String]
            let glPlain = GladiaLiveTranscriber.initBody(lang: "", vocabulary: [])
            check("gladia: init body carries language + vocabulary only when present",
                  glLangs == ["ko"] && glVocab == ["Kubernetes"]
                  && glPlain["language_config"] == nil && glPlain["realtime_processing"] == nil
                  && glPlain["sample_rate"] as? Int == 16000)
            var glGot: [(String, Bool)] = []
            let gl = GladiaLiveTranscriber(label: "t", locale: Locale(identifier: "ko-KR")) { s, f in glGot.append((s, f)) }
            gl.handle(#"{"type":"transcript","data":{"is_final":false,"utterance":{"text":" 안녕하세"}}}"#)
            gl.handle(#"{"type":"transcript","data":{"is_final":true,"utterance":{"text":"안녕하세요"}}}"#)
            gl.handle(#"{"type":"transcript","data":{"is_final":true,"utterance":{"text":"  "}}}"#)   // blank → dropped
            gl.handle(#"{"type":"audio_chunk","acknowledged":true}"#)                                  // ack → dropped
            gl.handle("junk")                                                                          // junk → dropped
            check("gladia: partial/final parsing (trimmed, junk dropped)", glGot.count == 2
                  && glGot[0] == ("안녕하세", false) && glGot[1] == ("안녕하세요", true))
            print(fails == 0 ? "selftest: ALL PASS" : "selftest: \(fails) FAILED")
            exit(fails == 0 ? 0 : 1)
        }

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
