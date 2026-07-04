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

// MARK: - helpers

/// Minimal Keychain string store for long-lived credentials (generic passwords under this app's service).
enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.ikhoon.macrec",
         kSecAttrAccount as String: account]
    }
    static func get(_ account: String) -> String? {
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
    /// Empty value deletes the item. Update-then-add (never delete-then-add: a failed add would
    /// silently drop the stored credential); non-success statuses are logged, not swallowed.
    /// Returns whether the operation actually succeeded (callers migrating data must check).
    @discardableResult
    static func set(_ account: String, _ value: String) -> Bool {
        guard !value.isEmpty else {
            let status = SecItemDelete(query(account) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { elog("keychain: delete '\(account)' failed (\(status))"); return false }
            return true
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            status = SecItemAdd(q as CFDictionary, nil)
        }
        if status != errSecSuccess { elog("keychain: save '\(account)' failed (\(status))"); return false }
        return true
    }
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
    private let filter = 4096         // ~256 ms adaptive tail (covers the speaker→mic delay + reverb)
    private let maxRef = 4096         // push-side ring cap — memory bound while the mic is stalled
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
    private var micBuf = [Int16]()    // mic samples awaiting a full frame
    private var st: OpaquePointer?    // Speex echo-canceller state
    private var lastMicNs: UInt64 = 0 // uptime of the previous cancelMic (gap detection)
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
        if let st { speex_echo_state_reset(st) }
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
        // Process all whole frames buffered so far. Always flow the mic (never starve transcription);
        // pair each frame with the most-recent reference. Snapshot that reference in ONE short locked
        // section (so the tap thread isn't blocked while speex runs, and draining is a single O(n)
        // removeFirst per buffer rather than one per frame). Any frame missing a reference is zero-padded —
        // it just isn't cancelled (it carries no echo, or the filter rides it out).
        let nFrames = micBuf.count / frame
        if nFrames > 0 {
            let want = nFrames * frame
            wkSnap.removeAll(keepingCapacity: true)
            refLock.lock()
            // Bound reference staleness (see maxLag): drop the OLDEST samples so that at most maxLag
            // remain after this drain — the mic then always pairs with a near-current reference. The
            // trim punches a small discontinuity into the fed reference, but that only happens after a
            // fill/drain imbalance (startup, mic stall) where the filter had lost causality anyway.
            let excess = refRing.count - (want + maxLag)
            if excess > 0 { refRing.removeFirst(excess); if debug { dbgTrim &+= excess } }
            let refTake = min(want, refRing.count)
            if refTake > 0 { wkSnap.append(contentsOf: refRing[0..<refTake]); refRing.removeFirst(refTake) }
            refLock.unlock()
            for f in 0..<nFrames {
                let m = f * frame
                for k in 0..<frame { wkMic[k] = micBuf[m + k] }
                for k in 0..<frame { let r = m + k; wkRef[k] = r < wkSnap.count ? wkSnap[r] : 0 }
                speex_echo_cancellation(st, &wkMic, &wkRef, &wkOut)   // (state, near-end/mic, far-end/ref, out)
                wkClean.append(contentsOf: wkOut)
            }
            micBuf.removeFirst(want)
        }
        if debug {   // cumulative counters (not per-call — per-call out aliases against the frame size)
            dbgN &+= 1; dbgIn &+= mic16.count; dbgOut &+= wkClean.count
            if dbgN % 90 == 0 {
                refLock.lock(); let rr = refRing.count; refLock.unlock()
                elog("echo(speex): cumIn=\(dbgIn) cumOut=\(dbgOut) refRing=\(rr) micBuf=\(micBuf.count) trimmed=\(dbgTrim)")
            }
        }
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, wkClean.count))) else { return nil }
        out.frameLength = AVAudioFrameCount(wkClean.count)
        if let ch = out.floatChannelData?[0] {
            for i in 0..<wkClean.count { ch[i] = Float(wkClean[i]) / 32768.0 }
        }
        return out
    }

    private var dbgN = 0, dbgIn = 0, dbgOut = 0, dbgTrim = 0   // debug counters (gated by `debug`)
    private func ensureState() {
        guard st == nil else { return }
        guard let s = speex_echo_state_init(Int32(frame), Int32(filter)) else {
            elog("echo(speex): echo-state init FAILED — falling back to raw mic")   // cancelMic guards on st == nil
            return
        }
        var rate: Int32 = 16000
        speex_echo_ctl(s, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
        st = s
        if debug { elog("echo(speex): AEC initialized (frame=\(frame) filter=\(filter))") }
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
    // 전용 suite (bundle id와 '달라야' 함 — suiteName==bundleID면 nil 반환/동작 안 함).
    // launchd가 .app 내부 바이너리를 직접 exec할 때 .standard 도메인이 안 잡히는 문제를 우회.
    // CLI에서 보려면: `defaults read com.ikhoon.macrec.prefs`
    static let suiteName = "com.ikhoon.macrec.prefs"
    static let d = UserDefaults(suiteName: suiteName) ?? .standard
    // 키 상수 (설정 UI와 공유)
    static let segment = "segmentSeconds", voiceMin = "voiceMinSeconds", lang = "whisperLang"
    static let keepAudio = "keepAudio", audioRetention = "audioRetentionDays", txtRetention = "transcriptRetentionDays"
    static let exclude = "excludeApps", txtDir = "transcriptsDir", vad = "vadEnabled", autoStart = "autoStart"
    static let cal = "useCalendarTitles", model = "whisperModelName"
    static let calendars = "calendarNames"              // calendar titles to source event titles from (empty = all)
    static let liveTimestamps = "liveTimestamps"        // show timestamps in the live-caption overlay
    static let captionLang = "liveCaptionLang"          // live-caption transcription locale ("" = system)
    static let translateTo = "liveTranslateTo"          // live-caption translation target ("" = off)
    static let liveFontSize = "liveFontSize"            // live-caption overlay font size (pt)
    static let liveOpacity = "liveOpacity"              // live-caption overlay opacity (0.3–1.0)
    static let liveSource = "liveSource"                // which speakers to transcribe live: both|other|me
    static let liveEngine = "liveEngine"                // live transcription engine: apple|whisper|deepgram (extensible)
    static let deepgramKey = "deepgramKey"              // LEGACY (pre-Keychain builds) — read once for migration, then removed
    static let autostartOffered = "autostartOffered"   // one-shot: auto-enabled the login item once
    static let systemAudio = "captureSystemAudio"       // capture other-party (system) audio via SCK
    static let echoReduce = "echoReduce"                // opt-in: duck speaker→mic echo using the tap as reference
    static let audioDir = "audioDir"                    // separate root for kept .wav (default OUTPUT_ROOT/audio)
    static let customModel = "customModelURL"           // custom model source (URL or local path) — overrides the popup

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
    var keepAudio: Bool                 // false면 전사만 남기고 오디오 삭제
    var audioRetentionDays: Int         // 0 = 무제한
    var transcriptRetentionDays: Int    // 0 = 무제한
    var excludeBundleIds: [String]

    static func load() -> EngineConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tdir = URL(fileURLWithPath: Pref.str(Pref.txtDir, "MR_TRANSCRIPTS_DIR",
                                                 home.appendingPathComponent("Documents/macrec/transcripts").path))
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

    init(excludeBundleIds: [String], onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.excludeBundleIds = excludeBundleIds
        self.onBuffer = onBuffer
    }

    func start() throws {
        stop()   // idempotent
        var exclude: [AudioObjectID] = []
        if let me = Self.processObject(pid: getpid()) { exclude.append(me) }
        for bid in excludeBundleIds {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bid) {
                if let o = Self.processObject(pid: app.processIdentifier) { exclude.append(o) }
            }
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
        // Speaker labels follow the transcription language (auto → the system language).
        let lang = cfg.whisperLang == "auto" ? Locale.current.language.languageCode?.identifier : cfg.whisperLang
        let (mine, theirs) = speakerLabels(forLanguage: lang)
        var merged: [(start: Double, who: String, text: String)] = []
        if let mic16 = convert16(seg.micURL) {
            merged += parse(runWhisper(mic16, cfg)).map { (start: $0.0, who: mine, text: $0.1) }
            try? FileManager.default.removeItem(at: mic16)
        }
        if let sys16 = convert16(seg.sysURL) {
            merged += parse(runWhisper(sys16, cfg)).map { (start: $0.0, who: theirs, text: $0.1) }
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
    private let customModelField = NSTextField()   // custom model URL or local path (overrides the popup)
    private let deepgramKeyField = NSSecureTextField()   // cloud live engine — the only off-device feature
    private let excludeTokens = NSTokenField()   // multiple bundle ids as tokens
    // Calendar titling: a scrollable checkbox list of the user's calendars (none checked = all).
    private var calChecks: [(name: String, box: NSButton)] = []
    private let keepAudioBtn = NSButton(checkboxWithTitle: "Keep audio (WAV) too", target: nil, action: nil)
    private let vadBtn = NSButton(checkboxWithTitle: "Remove noise/silence (VAD)", target: nil, action: nil)
    private let calBtn = NSButton(checkboxWithTitle: "Title transcripts from calendar events", target: nil, action: nil)
    private let loginBtn = NSButton(checkboxWithTitle: "Start at login (24/7 recording)", target: nil, action: nil)
    private let systemAudioBtn = NSButton(checkboxWithTitle: "Capture system audio (other participants)", target: nil, action: nil)
    private let echoBtn = NSButton(checkboxWithTitle: "Reduce mic echo on speakers (experimental)", target: nil, action: nil)
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
        w.setContentSize(NSSize(width: 560, height: 440))   // sized to the tabbed panes; buttons pinned bottom
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func labeled(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.alignment = .right; return l }

    private func buildForm() {
        segPopup.addItems(withTitles: segTitles); langPopup.addItems(withTitles: langTitles)
        modelPopup.addItems(withTitles: WhisperCatalog.all.map { $0.label })
        audioRetPopup.addItems(withTitles: retTitles); txtRetPopup.addItems(withTitles: retTitles)
        for f in [voiceField, dirField, audioDirField, customModelField, deepgramKeyField] { f.translatesAutoresizingMaskIntoConstraints = false }
        voiceField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        dirField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        audioDirField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        customModelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        customModelField.placeholderString = "https://…/ggml-model.bin  or  /path/to/model.bin"
        deepgramKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        deepgramKeyField.placeholderString = "Deepgram API key (console.deepgram.com) — audio streams to the cloud"

        excludeTokens.translatesAutoresizingMaskIntoConstraints = false
        excludeTokens.tokenizingCharacterSet = CharacterSet(charactersIn: ", ")
        excludeTokens.placeholderString = "e.g. com.spotify.client"
        excludeTokens.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        populateRunningApps()

        let calListCell = buildCalendarList()

        let chooseBtn = NSButton(title: "Choose…", target: self, action: #selector(chooseDir))
        let dirStack = NSStackView(views: [dirField, chooseBtn]); dirStack.orientation = .horizontal; dirStack.spacing = 6
        let audioChooseBtn = NSButton(title: "Choose…", target: self, action: #selector(chooseAudioDir))
        let audioStack = NSStackView(views: [audioDirField, audioChooseBtn]); audioStack.orientation = .horizontal; audioStack.spacing = 6

        // Grouped into tabs (each pane stays short) instead of one long scrolling form.
        func row(_ label: String, _ control: NSView) -> [NSView] { [labeled(label), control] }
        func tab(_ title: String, _ rows: [[NSView]]) -> NSTabViewItem {
            let grid = NSGridView(views: rows)
            grid.translatesAutoresizingMaskIntoConstraints = false
            grid.rowSpacing = 9; grid.columnSpacing = 18
            grid.column(at: 0).xPlacement = .trailing
            let pane = NSView(); pane.addSubview(grid)
            NSLayoutConstraint.activate([
                grid.topAnchor.constraint(equalTo: pane.topAnchor, constant: 20),
                grid.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
                grid.leadingAnchor.constraint(greaterThanOrEqualTo: pane.leadingAnchor, constant: 24),
            ])
            let item = NSTabViewItem(); item.label = title; item.view = pane
            return item
        }

        let tabs = NSTabView(); tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.focusRingType = .none   // clicking a tab otherwise shows a blue focus ring on top of the tab highlight ("double blue")
        tabs.addTabViewItem(tab("Recording", [
            row("Segment length (on the hour):", segPopup),
            row("", systemAudioBtn),
            row("", echoBtn),
            row("Min. speech (sec):", voiceField),
            row("", vadBtn),
            row("Excluded apps:", excludeTokens),
            row("Add a running app:", addAppPopup),
        ]))
        tabs.addTabViewItem(tab("Transcription", [
            row("Model:", modelPopup),
            row("…or custom model:", customModelField),
            row("Language:", langPopup),
        ]))
        tabs.addTabViewItem(tab("Titling", [
            row("", calBtn),
            row("Calendars:", calListCell),
        ]))
        tabs.addTabViewItem(tab("Live", [
            row("Deepgram API key:", deepgramKeyField),
        ]))
        tabs.addTabViewItem(tab("Storage", [
            row("", keepAudioBtn),
            row("Keep audio for:", audioRetPopup),
            row("Keep transcripts for:", txtRetPopup),
            row("Save transcripts to:", dirStack),
            row("Save audio to:", audioStack),
        ]))
        tabs.addTabViewItem(tab("General", [
            row("", loginBtn),
        ]))

        let saveBtn = NSButton(title: "Save & Apply", target: self, action: #selector(saveAndClose)); saveBtn.keyEquivalent = "\r"
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(closeOnly)); cancelBtn.keyEquivalent = "\u{1b}"
        let btns = NSStackView(views: [cancelBtn, saveBtn]); btns.orientation = .horizontal; btns.spacing = 10
        btns.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(tabs); content.addSubview(btns)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            tabs.bottomAnchor.constraint(equalTo: btns.topAnchor, constant: -12),
            btns.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            btns.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
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

    /// Fill the "add a calendar" popup with the user's event calendars (by title). Picking one
    /// appends it to the token field; an empty token field means "use all calendars".
    /// A scrollable checkbox list of the user's event calendars (none checked = all). Keeps every
    /// calendar visible even with many entries or long names.
    private func buildCalendarList() -> NSView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        calChecks = []
        let names = CalendarLookup.availableCalendarNames()
        if names.isEmpty {
            let l = NSTextField(labelWithString: "No calendars available (grant Calendar access, then reopen).")
            l.textColor = .secondaryLabelColor; l.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(l)
        }
        for name in names {
            let box = NSButton(checkboxWithTitle: name, target: nil, action: nil)
            stack.addArrangedSubview(box); calChecks.append((name, box))
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        // Grow to fit all calendars up to a cap, then scroll (instead of a fixed short box).
        let naturalH = CGFloat(max(1, names.count)) * 21 + 14
        scroll.heightAnchor.constraint(equalToConstant: min(naturalH, 220)).isActive = true
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        ])
        let hint = NSTextField(labelWithString: "None checked = all calendars")
        hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabelColor
        let cell = NSStackView(views: [scroll, hint]); cell.orientation = .vertical
        cell.alignment = .leading; cell.spacing = 3
        return cell
    }

    private func idx<T: Equatable>(_ v: T, _ arr: [T]) -> Int { arr.firstIndex(of: v) ?? 0 }

    private func load() {
        let c = EngineConfig.load()
        segPopup.selectItem(at: idx(Int(c.segmentSeconds), segValues))
        langPopup.selectItem(at: idx(c.whisperLang, langValues))
        modelPopup.selectItem(at: idx(Pref.str(Pref.model, "MR_WHISPER_MODEL", WhisperCatalog.defaultName), modelNames))
        customModelField.stringValue = Pref.str(Pref.customModel, "MR_MODEL_URL", "")
        deepgramKeyField.stringValue = Keychain.get("deepgram") ?? ""
        voiceField.stringValue = String(Int(c.voiceMinSeconds))
        vadBtn.state = c.vadEnabled ? .on : .off
        systemAudioBtn.state = Pref.bool(Pref.systemAudio, "MR_SYSTEM_AUDIO", true) ? .on : .off
        echoBtn.state = Pref.bool(Pref.echoReduce, "MR_ECHO_REDUCE", false) ? .on : .off
        calBtn.state = c.useCalendarTitles ? .on : .off
        keepAudioBtn.state = c.keepAudio ? .on : .off
        audioRetPopup.selectItem(at: idx(c.audioRetentionDays, retValues))
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
        d.set(customModelField.stringValue.trimmingCharacters(in: .whitespaces), forKey: Pref.customModel)
        Keychain.set("deepgram", deepgramKeyField.stringValue.trimmingCharacters(in: .whitespaces))   // credential → Keychain, not prefs
        d.set(Double(Int(voiceField.stringValue) ?? 5), forKey: Pref.voiceMin)
        d.set(vadBtn.state == .on, forKey: Pref.vad)
        d.set(systemAudioBtn.state == .on, forKey: Pref.systemAudio)
        d.set(echoBtn.state == .on, forKey: Pref.echoReduce)
        d.set(calBtn.state == .on, forKey: Pref.cal)
        d.set(keepAudioBtn.state == .on, forKey: Pref.keepAudio)
        d.set(retValues[max(0, audioRetPopup.indexOfSelectedItem)], forKey: Pref.audioRetention)
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
/// — for a language code. Falls back to English so non-Korean users don't see 나/상대.
func speakerLabels(forLanguage lang: String?) -> (mine: String, theirs: String) {
    switch lang {
    case "ko": return ("나", "상대")
    case "ja": return ("私", "相手")
    case "zh": return ("我", "对方")
    default:   return ("Me", "Them")
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
// source (mic → 나, system → 상대) for low-latency live captions in a floating panel. whisper-cli on
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

/// Selectable live engine. Extensible: add a case, a title, and a branch in `makeTranscriber`.
enum LiveEngine: String, CaseIterable {
    case apple, whisper, deepgram
    static var current: LiveEngine { LiveEngine(rawValue: Pref.d.string(forKey: Pref.liveEngine) ?? "") ?? .apple }
    var title: String {
        switch self {
        case .apple:    return "Apple"
        case .whisper:  return "Whisper"
        case .deepgram: return "Deepgram ☁"
        }
    }
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
        // Whisper hallucinates ("감사합니다", "Thank you"…) on silence — only run it once the segment holds
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
        p.arguments = ["-m", cfg.whisperModel, "-f", wavURL.path, "-l", lang, "-nt", "-np", "-sns",
                       "-bs", "1", "-t", String(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))]
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

    static var apiKey: String {
        if let k = Keychain.get("deepgram") { return k }
        // One-time migration: pre-Keychain builds kept the key in prefs — move it out. The legacy
        // value is removed ONLY once the Keychain write is confirmed (a failed save must not drop
        // the sole stored credential).
        if let k = Pref.d.string(forKey: Pref.deepgramKey), !k.isEmpty {
            if Keychain.set("deepgram", k) { Pref.d.removeObject(forKey: Pref.deepgramKey) }
            return k
        }
        return ProcessInfo.processInfo.environment["MR_DEEPGRAM_KEY"] ?? ""
    }

    init(label: String, locale: Locale, onLocale: ((Locale) -> Void)? = nil,
         onUpdate: @escaping (String, Bool) -> Void) {
        self.label = label; self.locale = locale; self.onLocale = onLocale; self.onUpdate = onUpdate
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
        var comps = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        comps.queryItems = [
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
        var req = URLRequest(url: comps.url!)
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        q.async { [self] in   // all connection state (task/session/pending/lastSentAt/stopped) lives on q
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
/// names are endonyms (한국어, 日本語 …) for quick recognition; translation is prefixed with →.
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
    private var lines: [(speaker: String, text: String, translated: String?, final: Bool, time: Date)] = []
    private var mineLabel = ""   // label used for the mic track (for speaker coloring)
    private var showLabels = true   // false in single-speaker modes (one voice → the label is redundant)
    private var lastTranslateAt: [String: Double] = [:]   // per-speaker throttle for live translation
    private let translateThrottle = 0.5
    // Last-applied live config — so reconfigure() can no-op on unchanged values and avoid needless
    // analyzer rebuilds (each rebuild re-pays the ~model warm-up).
    private var curLocaleId = "", curEngine = "", curSource = "", curTranslateId = ""
    private var engineGen = 0   // bumped on translator rebuild; a translate Task from an older gen is ignored
    private let maxLines = 12
    private(set) var active = false

    /// Menu toggle (main thread).
    func toggle() { active ? stop() : start() }

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
        // Update this speaker's in-progress (non-final) line, or start a new one.
        if let i = lines.lastIndex(where: { $0.speaker == speaker && !$0.final }) {
            lines[i].text = text; lines[i].final = final
        } else {
            lines.append((speaker, text, nil, final, Date()))
        }
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        render()
        // Translate the live text too (not just finals), throttled per speaker so it streams along.
        if let translator, !text.isEmpty {
            let now = ProcessInfo.processInfo.systemUptime
            if final || now - (lastTranslateAt[speaker] ?? 0) >= translateThrottle {
                lastTranslateAt[speaker] = now
                let gen = engineGen
                Task { [weak self] in
                    guard let out = await translator.translate(text) else { return }
                    await MainActor.run { guard let self, self.engineGen == gen else { return }   // drop stale-generation results
                        self.setTranslation(speaker, text, out) }
                }
            }
        }
    }
    private func setTranslation(_ speaker: String, _ original: String, _ translated: String) {
        guard active else { return }
        // Prefer the exact source line; else the speaker's current line (volatile text has since moved on).
        let i = lines.lastIndex(where: { $0.speaker == speaker && $0.text == original })
            ?? lines.lastIndex(where: { $0.speaker == speaker && !$0.final })   // else the current in-progress line
        guard let i else { return }
        lines[i].translated = translated
        render()
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

/// Floating always-on-top panel showing the live captions. A compact control bar along the top holds
/// the live settings (language, who to transcribe, translation, text size, timestamps) so changes take
/// effect immediately; opacity is the drag slider along the bottom. Nothing lives in the Settings window.
@available(macOS 26, *)
final class LiveCaptionWindow: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let textView = NSTextView()
    private let onClose: () -> Void
    private let onReconfigure: () -> Void   // language / source / translation changed → rebuild the engine
    private let onRestyle: () -> Void        // text size / timestamps changed → just re-render
    private var suppressCloseCallback = false
    private let langPopup = NSPopUpButton(), sourcePopup = NSPopUpButton(), translatePopup = NSPopUpButton()
    private let tsToggle = NSButton(checkboxWithTitle: "Time", target: nil, action: nil)
    private static let titleIcon = "🎙️"           // beautifies the "macrec live" title

    init(onClose: @escaping () -> Void, onReconfigure: @escaping () -> Void, onRestyle: @escaping () -> Void) {
        self.onClose = onClose; self.onReconfigure = onReconfigure; self.onRestyle = onRestyle
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 150),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "\(Self.titleIcon) macrec live"
        panel.alphaValue = CGFloat(min(1.0, max(0.3, Pref.dbl(Pref.liveOpacity, "MR_LIVE_OPACITY", 1.0))))
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
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

        // --- captions (scrollable text) fill the whole content (opacity moved up to the control bar) ---
        let content = panel.contentView!
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
        content.addSubview(scroll)
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
        // Engine select box — Apple (fast) vs Whisper (accurate / better Korean).
        let enginePopup = NSPopUpButton()
        fill(enginePopup, LiveEngine.allCases.map { $0.title }, LiveEngine.allCases.firstIndex(of: .current) ?? 0,
             "Engine — Apple: fast · Whisper: accurate (better Korean)", #selector(engineChanged(_:)))
        // Opacity drag slider, now on the top bar (was a bottom strip).
        let opacity = NSSlider(value: Double(panel.alphaValue), minValue: 0.3, maxValue: 1.0,
                               target: self, action: #selector(opacityChanged(_:)))
        opacity.controlSize = .mini; opacity.toolTip = "Overlay opacity"
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
        let bar = NSStackView(views: [
            icon("cpu", "Engine"), enginePopup,
            icon("globe", "Caption language"), langPopup,
            icon("person.2", "Who to transcribe"), sourcePopup,
            icon("character.bubble", "Translate to"), translatePopup,
            spacer, aMinus, aPlus, tsToggle, opacity])
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
    @objc private func engineChanged(_ s: NSPopUpButton) {
        let engines = LiveEngine.allCases
        let e = engines[min(max(0, s.indexOfSelectedItem), engines.count - 1)]
        Pref.d.set(e.rawValue, forKey: Pref.liveEngine); onReconfigure()
    }

    @objc private func opacityChanged(_ s: NSSlider) {
        panel.alphaValue = CGFloat(s.doubleValue)
        Pref.d.set(s.doubleValue, forKey: Pref.liveOpacity)
    }

    func show() {
        if let f = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.maxX - panel.frame.width - 24, y: f.minY + 24))
        }
        panel.orderFrontRegardless()
    }
    func close() { suppressCloseCallback = true; panel.close() }

    /// Show the active transcription language in the title bar (human name, e.g. "🎙️ macrec live · Korean").
    func setLanguage(_ name: String) { panel.title = "\(Self.titleIcon) macrec live · \(name)" }
    /// Shown while the analyzer warms up (model/ANE load) — the overlay is otherwise blank for ~10s.
    func setPreparing() { panel.title = "\(Self.titleIcon) macrec live · starting…" }

    private let tsFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// Render for glanceable reading. With both speakers each gets a distinct tint (teal = you, orange =
    /// them) on a bold label; a single speaker drops the label and uses the primary color. All text starts
    /// at one shared column via a tab stop, and wrapped lines hang-indent to that same column — so line 2+
    /// aligns flush under the text regardless of the timestamp/label prefix width.
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
        let hasPrefix = showTimestamps || showLabels
        let col = hasPrefix ? tsW + labelW + 8 : 0
        let tsBaseline = showTimestamps ? (textFont.capHeight - tsFont.capHeight) / 2 : 0   // vertically center the smaller timestamp
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = 0; para.headIndent = col
        para.lineHeightMultiple = 1.1; para.paragraphSpacing = 4
        if hasPrefix { para.tabStops = [NSTextTab(textAlignment: .left, location: col)]; para.defaultTabInterval = col }
        let trans = NSMutableParagraphStyle()
        trans.firstLineHeadIndent = col; trans.headIndent = col + w("↳ ", transFont); trans.lineHeightMultiple = 1.1
        let out = NSMutableAttributedString()
        for (i, l) in lines.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            let tint: NSColor = l.mine ? .systemTeal : .systemOrange   // colors the LABEL only (both-speaker mode)
            if showTimestamps {
                out.append(NSAttributedString(string: "\(tsFormatter.string(from: l.time))  ", attributes: [
                    .font: tsFont, .foregroundColor: NSColor.secondaryLabelColor, .baselineOffset: tsBaseline, .paragraphStyle: para]))
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
                    .font: transFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: trans]))
                out.append(NSAttributedString(string: t, attributes: [   // readable, but a touch dimmer than the original → clear hierarchy
                    .font: transFont, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.8), .paragraphStyle: trans]))
            }
        }
        textView.textStorage?.setAttributedString(out)
        textView.scrollToEndOfDocument(nil)
    }

    // User clicked the panel's close button → tear the session down (unless we closed it ourselves).
    func windowWillClose(_ notification: Notification) { if !suppressCloseCallback { onClose() } }
}

// MARK: - menu-bar app (tray icon)

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var engine: RecordingEngine?
    private var stopTask: Task<Void, Never>?   // in-flight engine stop (pause) — resume/restart await it so
                                               // two capture pipelines never overlap on the shared audio state
    private var statusLine: NSMenuItem!
    private var levelItem: NSMenuItem!
    private var lastSavedLine: NSMenuItem!
    private var modelLine: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var liveItem: NSMenuItem?   // "Live captions" toggle (macOS 26+)
    private var paused = false
    private var didAutoPrompt = false   // only auto-open the permission prompts/Settings once per launch
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
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.ikhoon.macrec.openMenu"), object: nil, queue: .main
        ) { [weak self] _ in self?.openMenu() }
        CalendarLookup.requestAccess()   // one-time Calendar prompt (for titling transcripts)
        setupModelDownload()             // first-run: fetch the large model, show progress in the menu
        LoginItem.autoEnableOnceIfDistributed()   // distributed app: enable 24/7 autostart on first run
        startEngine()
        installStopHandler { [weak self] in
            self?.stopEngineSync()
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
        // Hug the glyph's real width (+ a hair) so there's no wide L/R slack — WITHOUT touching pointSize
        // or imagePosition (fixed length keeps the vertical centering that variableLength/imageOnly broke).
        let glyphW = img?.size.width ?? 22
        statusItem.length = ceil(glyphW) + 4
        elog("icon set (recording=\(recording)), glyphW=\(glyphW), length=\(statusItem.length)")
    }

    private func item(_ title: String, _ sel: Selector, _ key: String = "", symbol: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key); i.target = self
        if !symbol.isEmpty { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        return i
    }

    private func buildMenu() {
        setIcon(recording: false)
        let menu = NSMenu()
        // About on top (macOS convention), then a divider.
        menu.addItem(item("About macrec", #selector(showAbout), symbol: "info.circle"))
        menu.addItem(.separator())
        // Live status rows (disabled — informational; they carry their own inline status glyphs).
        statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: ""); statusLine.isEnabled = false
        levelItem = NSMenuItem(title: "🎤 —   🔊 —", action: nil, keyEquivalent: ""); levelItem.isEnabled = false
        lastSavedLine = NSMenuItem(title: "", action: nil, keyEquivalent: ""); lastSavedLine.isEnabled = false; lastSavedLine.isHidden = true
        modelLine = NSMenuItem(title: "", action: nil, keyEquivalent: ""); modelLine.isEnabled = false; modelLine.isHidden = true
        menu.addItem(statusLine); menu.addItem(levelItem); menu.addItem(lastSavedLine); menu.addItem(modelLine)
        menu.addItem(.separator())
        // Transcribe now — custom-view button so clicking it does NOT dismiss the menu (watch the
        // live meter + status update in place). Its leading icon aligns with the imaged items below.
        let tItem = NSMenuItem()
        let tView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        let tBtn = NSButton(title: "Transcribe now", target: self, action: #selector(flushNow))
        tBtn.isBordered = false; tBtn.alignment = .left; tBtn.font = NSFont.menuFont(ofSize: 0)
        tBtn.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Transcribe now")
        tBtn.imagePosition = .imageLeading
        // AppKit's default image↔title gap matches the standard imaged items; a small left inset
        // lines the icon up with them. (No leading space in the title — that would leak into the
        // accessibility label and render inconsistently across fonts.)
        tBtn.frame = NSRect(x: 14, y: 1, width: 221, height: 20)
        tView.addSubview(tBtn); tItem.view = tView
        menu.addItem(tItem)
        toggleItem = item("Pause", #selector(togglePause), symbol: "pause.circle"); menu.addItem(toggleItem)
        if #available(macOS 26, *) {   // real-time caption overlay (on-device SpeechAnalyzer)
            let li = item("Live captions", #selector(toggleLive), symbol: "captions.bubble")
            li.state = LiveCaptions.shared.active ? .on : .off
            liveItem = li; menu.addItem(li)
        }
        menu.addItem(.separator())
        menu.addItem(item("Grant permissions…", #selector(grantPermissions), symbol: "hand.raised"))
        menu.addItem(item("Settings…", #selector(openSettings), ",", symbol: "gearshape"))
        menu.addItem(item("Open transcripts folder", #selector(openTranscripts), "o", symbol: "folder"))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), "q", symbol: "power"))
        menu.delegate = self
        statusItem.menu = menu
    }

    // Live input meter — only updates while the menu is open (cheap, and answers "is it working?").
    func menuWillOpen(_ menu: NSMenu) {
        updateLevels()
        // Reflect the live-captions state in case it was turned off by closing the floating panel.
        if #available(macOS 26, *) { liveItem?.state = LiveCaptions.shared.active ? .on : .off }
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
        toggleItem?.image = NSImage(systemSymbolName: paused ? "play.circle" : "pause.circle", accessibilityDescription: nil)
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
                await MainActor.run {
                    self.engine = nil; self.setIcon(recording: false)
                    self.refresh("⚠ Grant System Audio Recording + Microphone to macrec")
                    if !self.didAutoPrompt { self.didAutoPrompt = true; self.grantPermissions() }  // fire prompts + open Settings once
                }
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
            paused = false; refresh("Resuming…")
            // Pause's stop is fire-and-forget (instant UI); a quick resume must WAIT for it, or two
            // capture pipelines briefly overlap (two mic queues + two taps on the shared audio state).
            // stopTask stays set until the stop has truly finished — clearing it on read would let a
            // pause→resume→pause→resume flurry start an engine while the first stop is still in flight.
            let stopping = stopTask
            Task {
                if let stopping { _ = await stopping.value }
                await MainActor.run {
                    if self.stopTask == stopping { self.stopTask = nil }
                    if !self.paused && self.engine == nil { self.startEngine() }
                }
            }
        } else {
            paused = true; setIcon(recording: false); refresh("⏸ Paused")
            if let eng = engine { engine = nil; stopTask = Task { await eng.stop() } }
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
        let pending = stopTask   // settings saved while paused → that stop may still be in flight; kept set
        Task {                   // until done so an interleaved resume can't slip past it (see togglePause)
            if let pending { _ = await pending.value }
            if let old = old { await old.stop() }
            await MainActor.run {
                if self.stopTask == pending { self.stopTask = nil }
                if !self.paused && self.engine == nil { self.startEngine() }
            }
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

        // Subcommands: help / version (accept the common flag spellings too).
        if let a = args.first, ["help", "--help", "-h"].contains(a) { printMacrecHelp(); exit(0) }
        if let a = args.first, ["version", "--version", "-v"].contains(a) { print("macrec \(macrecVersion)"); exit(0) }

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
            check("AEC framing: mic flows (out ≈ in, with reference)", ecIn - ecOut >= 0 && ecIn - ecOut <= 256)
            EchoCanceller.shared.reset()   // no reference at all → mic must still pass through, never starve
            var nrIn = 0, nrOut = 0
            for _ in 0..<40 { nrOut += EchoCanceller.shared.cancelMic(ecBuf(171)).map { Int($0.frameLength) } ?? -99999; nrIn += 171 }
            check("AEC framing: mic flows (out ≈ in, no reference)", nrIn - nrOut >= 0 && nrIn - nrOut <= 256)
            // Staleness invariant: a reference backlog (tap running while the mic spins up / stalls) must be
            // trimmed on drain so the mic pairs with a near-current reference — a persistent backlog makes the
            // causal filter cancel 0 dB for the whole session (regression found by adversarial review).
            EchoCanceller.shared.reset()
            _ = EchoCanceller.shared.cancelMic(ecBuf(256))          // prime (first call after reset self-heals)
            EchoCanceller.shared.pushReference(ecBuf(6000))         // backlog far beyond any real echo delay
            _ = EchoCanceller.shared.cancelMic(ecBuf(512))          // one drain must re-anchor the ring
            check("AEC staleness: ring trimmed to ≤ 512 after drain", EchoCanceller.shared.refDepthForTest <= 512)
            // Gap/reset invariant: buffered mic residue must not leak into a later stream.
            EchoCanceller.shared.reset()
            _ = EchoCanceller.shared.cancelMic(ecBuf(100))          // sub-frame residue stays buffered…
            let residue = EchoCanceller.shared.micDepthForTest == 100
            EchoCanceller.shared.reset()                            // …until a reset (or a mic-gap self-heal)
            check("AEC reset: buffered mic residue cleared", residue && EchoCanceller.shared.micDepthForTest == 0)
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
            let sigQ = DispatchQueue(label: "meeting-capture.signal")
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
