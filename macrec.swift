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
            // Credential stays on THIS machine (no backup/migration restore) but is readable after login.
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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
    private let q = DispatchQueue(label: "meeting-capture.mic")
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
    static let audioRawDays = "audioRawDays"            // days a WAV stays raw before AAC compression (0 = never compress)
    static let exclude = "excludeApps", txtDir = "transcriptsDir", vad = "vadEnabled", autoStart = "autoStart"
    static let cal = "useCalendarTitles", model = "whisperModelName"
    static let calendars = "calendarNames"              // calendar titles to source event titles from (empty = all)
    static let liveTimestamps = "liveTimestamps"        // show timestamps in the live-caption overlay
    static let captionLang = "liveCaptionLang"          // live-caption transcription locale ("" = system)
    static let translateTo = "liveTranslateTo"          // live-caption translation target ("" = off)
    static let liveFontSize = "liveFontSize"            // live-caption overlay font size (pt)
    static let liveOpacity = "liveOpacity"              // live-caption overlay opacity (0.3–1.0)
    static let liveBarCollapsed = "liveBarCollapsed"    // overlay control strip collapsed (space for captions)
    static let liveSource = "liveSource"                // which speakers to transcribe live: both|other|me
    static let liveEngine = "liveEngine"                // live transcription engine: apple|whisper|deepgram (extensible)
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
    var audioRawDays: Int               // WAV 그대로 두는 일수, 이후 AAC 압축 (0 = 압축 안 함)
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

/// Transcript/audio file base: start datetime + END time — "2026-07-05-2100-2130". Both endpoints
/// in the name because "Transcribe now" cuts mid-segment: consecutive files must show where one
/// stops and the next begins. A segment past midnight keeps the START's date ("…-2350-0020").
func transcriptBaseName(start: Date, end: Date, timeZone: TimeZone = .current) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone
    f.dateFormat = "yyyy-MM-dd-HHmm"
    let g = DateFormatter(); g.locale = Locale(identifier: "en_US_POSIX"); g.timeZone = timeZone
    g.dateFormat = "HHmm"
    return "\(f.string(from: start))-\(g.string(from: end))"
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
    private static func runWhisper(_ wav16: URL, _ cfg: EngineConfig, hints: String = "") -> String {
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
        let hints = transcriptionHints(start: seg.start, end: seg.start.addingTimeInterval(seg.durationSeconds))
        if !hints.isEmpty { elog("transcribe: hints (\(hints.split(separator: ",").count) terms)") }
        var merged: [(start: Double, who: String, text: String)] = []
        if let mic16 = convert16(seg.micURL) {
            merged += parse(runWhisper(mic16, cfg, hints: hints)).map { (start: $0.0, who: mine, text: $0.1) }
            try? FileManager.default.removeItem(at: mic16)
        }
        if let sys16 = convert16(seg.sysURL) {
            merged += parse(runWhisper(sys16, cfg, hints: hints)).map { (start: $0.0, who: theirs, text: $0.1) }
            try? FileManager.default.removeItem(at: sys16)
        }
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
    private let timerQueue = DispatchQueue(label: "meeting-recorder.timer")
    private let processQueue = DispatchQueue(label: "meeting-recorder.process")  // serial: transcribe one at a time
    private var timer: DispatchSourceTimer?
    private(set) var running = false
    private var recovering = false
    private var suspended = false   // true while the display/system is asleep
    var onTranscriptSaved: ((String) -> Void)?   // (메시지) — UI 상태 갱신용
    var onTranscriptURL: ((URL) -> Void)?        // 저장된 전사 파일 경로 — 알림 클릭 → 파일 열기
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
        // Writers are swapped/released ON rec.queue at every rotation; reading the refs off-queue
        // races that swap (review finding: the 1 Hz voice poll could catch the old writer's final
        // release → over-release). Snapshot on the queue — its work items are short buffer appends,
        // and nothing on rec.queue ever syncs back to main, so this can't deadlock.
        let rec = session.rec
        return rec.queue.sync { (rec.micWriter?.recentLevel ?? 0, rec.sysWriter?.recentLevel ?? 0) }
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
            if n > 0 { elog("engine: retention — md \(n)개 삭제(>\(cfg.transcriptRetentionDays)일)") }
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
            elog("engine: retention — 오디오 \(deleted)개 삭제, \(archived)개 AAC 압축(raw>\(cfg.audioRawDays)일)")
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
            let url = try writeTranscript(seg: seg, text: text, mixed: mixed)
            onTranscriptURL?(url)
            onTranscriptSaved?("Saved: \(url.lastPathComponent)")
            if let cmd = postProcessInvocationFromPrefs(transcriptPath: url.path) { runPostProcessCommand(cmd) }
        } catch { elog("engine: writeTranscript: \(error)") }
    }

    @discardableResult
    private func writeTranscript(seg: CompletedSegment, text: String, mixed: URL?) throws -> URL {
        let fm = FileManager.default
        let dayF = DateFormatter(); dayF.locale = Locale(identifier: "en_US_POSIX"); dayF.dateFormat = "yyyy-MM-dd"
        let hmF = DateFormatter(); hmF.locale = Locale(identifier: "en_US_POSIX"); hmF.dateFormat = "HH:mm"
        let monthF = DateFormatter(); monthF.locale = Locale(identifier: "en_US_POSIX"); monthF.dateFormat = "yyyy-MM"

        // Organize transcripts into monthly subfolders: transcripts/YYYY-MM/…  (audio under YYYY-MM/audio/).
        let monthDir = cfg.transcriptsDir.appendingPathComponent(monthF.string(from: seg.start), isDirectory: true)
        try fm.createDirectory(at: monthDir, withIntermediateDirectories: true)
        let end = seg.start.addingTimeInterval(seg.durationSeconds)
        let mins = Int((seg.durationSeconds + 30) / 60)

        // Title the transcript from the overlapping calendar event (prefers ones with a meeting link).
        let l10n = TranscriptL10n.current
        let event = cfg.useCalendarTitles ? CalendarLookup.match(start: seg.start, end: end) : nil
        let title = event?.title ?? l10n.autoTitle
        let base = transcriptBaseName(start: seg.start, end: end)
        let slug = event.map { "\(base)-\(slugify($0.title))" } ?? base

        // keep the mixed WAV per the keepAudio setting (mixed is nil when keepAudio is off)
        var audioLine = "- \(l10n.audio): \(l10n.audioNotKept)"
        if cfg.keepAudio, let mixed = mixed {
            let audioMonthDir = cfg.audioDir.appendingPathComponent(monthF.string(from: seg.start), isDirectory: true)
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
            day: dayF.string(from: seg.start), hmStart: hmF.string(from: seg.start), hmEnd: hmF.string(from: end),
            mins: mins,
            micVoiced: seg.micVoicedSeconds, sysVoiced: seg.sysVoicedSeconds,
            modelName: URL(fileURLWithPath: cfg.whisperModel).lastPathComponent,
            audioLine: audioLine, meta: meta, excludes: cfg.excludeBundleIds.joined(separator: ", "),
            bodyMine: bodyMine, bodyTheirs: bodyTheirs,
            body: body)
        let mdURL = monthDir.appendingPathComponent("\(slug).md")
        try doc.markdown(l10n).write(to: mdURL, atomically: true, encoding: .utf8)
        elog("engine:   → 전사 저장: \(mdURL.path)")
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

// MARK: - transcript-level echo suppression (belt to the AEC's braces)
//
// The acoustic canceller attenuates the speaker→mic echo ~15-26 dB, but live engines still transcribe
// the residual: the far-end shows up again under the MIC speaker as an (often garbled) copy a moment
// later. Acoustic cancellation can't fully win that fight, so we also suppress at the TRANSCRIPT
// level: a mic line whose tokens are largely contained in a recent far-end line is an echo, not the
// user. One-directional (system audio can't contain the user's voice) and length-guarded so genuine
// short replies ("yes", "그렇죠") are never eaten.

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

/// Where the automatic summary lands: "" = next to the transcript as `<name>.summary.md`;
/// otherwise `<dir>/<name>.summary.md` (tilde expanded). Pure + testable.
func summaryOutputPath(transcriptPath: String, outDir: String) -> String {
    let t = URL(fileURLWithPath: transcriptPath)
    let name = t.deletingPathExtension().lastPathComponent + ".summary.md"
    let dir = outDir.trimmingCharacters(in: .whitespacesAndNewlines)
    if dir.isEmpty { return t.deletingLastPathComponent().appendingPathComponent(name).path }
    return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent(name).path
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

// MARK: - settings window (NSGridView form, persists to UserDefaults)

/// Scroll-document container whose origin is the TOP (AppKit views are bottom-up by default) —
/// forms in a scroll view should start at the top and grow downward.
final class FlippedDocView: NSView { override var isFlipped: Bool { true } }

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

/// Form-row role markers: a row's ROLE travels with its views, so grid styling (header merges, caption
/// padding) is derived instead of hand-indexed — inserting a row can no longer desync a styling list.
final class SectionHeaderCell: NSStackView {}   // col 0 → full-width merged section header
final class CaptionCell: NSTextField {}         // col 0 → full-width intro note; col 1 → field caption

/// Find the first NSGridView in a view tree (the settings selftest inspects panes through their
/// scroll-view wrapper).
func firstGrid(in view: NSView?) -> NSGridView? {
    guard let view else { return nil }
    if let g = view as? NSGridView { return g }
    if let sv = view as? NSScrollView { return firstGrid(in: sv.documentView) }
    for sub in view.subviews { if let g = firstGrid(in: sub) { return g } }
    return nil
}

/// Derive (headers, notes) row indices from marker types. Pure + testable (see `macrec selftest`).
func formRowRoles(_ rows: [[NSView]]) -> (headers: [Int], notes: [Int]) {
    var headers: [Int] = [], notes: [Int] = []
    for (i, r) in rows.enumerated() {
        if r.first is SectionHeaderCell || r.first is CaptionCell { headers.append(i) }
        else if r.count > 1, r[1] is CaptionCell { notes.append(i) }
    }
    return (headers, notes)
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSComboBoxDelegate {

    /// A field the parser can't read must LOOK broken while typing — schedule fields silently
    /// falling open to "record everything" is a privacy failure; a retention typo would silently
    /// keep the last saved period. Invalid input turns red and is ignored on save.
    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        if f === schedDaysField || f === schedHoursField { recolorScheduleFields() }
        if f === audioRawCombo || f === audioRetCombo { recolorRetentionCombos() }
    }

    fileprivate func recolorScheduleFields() {
        schedDaysField.textColor = RecordSchedule.daysValid(schedDaysField.stringValue) ? .labelColor : .systemRed
        schedHoursField.textColor = RecordSchedule.hoursValid(schedHoursField.stringValue) ? .labelColor : .systemRed
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
    private(set) var tabsForTest: NSTabView?   // selftest hook: every pane must host its grid in a scroll view
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
    private let ppModePopup = NSPopUpButton()     // Off / Automatic summary (built-in) / Custom command
    private let ppModeValues = ["off", "summary", "shell"], ppModeTitles = ["Off", "Automatic summary", "Custom command"]
    private let runnerPopup = NSPopUpButton()     // which agent CLI writes the summary
    private let runnerValues = ["claude", "codex", "gemini"], runnerTitles = ["Claude CLI", "Codex CLI", "Gemini CLI"]
    private let promptView = NSTextView()         // summary prompt — a real TEXT AREA (prompts are sentences)
    private let promptFileField = NSTextField()   // external prompt file — overrides the text when readable
    private let promptScroll = NSScrollView()     // its bordered, scrolling host
    private let summaryOutField = NSTextField()   // summary output dir ("" = next to the transcript)
    private var summaryChooseBtn: NSButton?       // folder picker for the summary output dir
    private let hintsTermsField = NSTextField()   // hint terms (comma/newline separated)
    private let hintsFileField = NSTextField()    // external hints file path
    private let schedBtn = NSButton(checkboxWithTitle: "Record only on a schedule", target: nil, action: nil)
    private let schedDaysField = NSTextField()    // "mon-fri" / "mon,wed,fri"
    private let schedHoursField = NSTextField()   // "10:00-12:00, 13:00-19:00" (gap = lunch)
    private let hintsCalBtn = NSButton(checkboxWithTitle: "Add the meeting's title & attendees from Calendar",
                                       target: nil, action: nil)
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
    private let transcriptLangPopup = NSPopUpButton()
    private let tLangValues = ["", "en", "ko", "ja"], tLangTitles = ["System", "English", "한국어", "日本語"]
    private let modelNames = WhisperCatalog.all.map { $0.name }   // popup order matches WhisperCatalog.all
    private let retValues = [7, 30, 90, 180, 365, 0]
    private let retTitles = ["7 days", "30 days", "90 days", "180 days", "1 year", "Unlimited"]

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "macrec — Settings"
        super.init(window: w)
        w.delegate = self
        buildForm()
        load()
        // Size the window to the DENSEST tab's measured content (user ask: no scrolling by default).
        // Derived, not hardcoded — adding rows can't silently reintroduce the scroll. The scroll pane
        // stays as the safety net for small screens / manual shrinking.
        let maxGrid = tabsForTest?.tabViewItems
            .compactMap { firstGrid(in: $0.view)?.fittingSize }
            .reduce(NSSize(width: 520, height: 400)) { NSSize(width: max($0.width, $1.width),
                                                              height: max($0.height, $1.height)) }
            ?? NSSize(width: 520, height: 400)
        w.setContentSize(NSSize(width: max(560, maxGrid.width + 80),
                                height: min(maxGrid.height + 130, (NSScreen.main?.visibleFrame.height ?? 900) - 60)))
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func labeled(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.alignment = .right; return l }

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
        dirField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        audioDirField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
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
        for f in [schedDaysField, schedHoursField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
            f.delegate = self   // live red-on-invalid feedback (fail-open would record 24/7 silently)
        }
        schedDaysField.placeholderString = "mon-fri"
        schedHoursField.placeholderString = "10:00-12:00, 13:00-19:00"
        for f in [hintsTermsField, hintsFileField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        hintsTermsField.placeholderString = "Kubernetes, gRPC, 김철수, …"
        hintsFileField.placeholderString = "~/notes/hints.txt"
        // PATH-carrying fields: a long path used to truncate at the TAIL, hiding the part that matters
        // (user report on "Save summary to"). Truncate the HEAD instead ("…/notes/summaries"), widen,
        // and mirror the full value into the tooltip on load (see load()).
        for f in [dirField, audioDirField, customModelField, hintsFileField, promptFileField,
                  summaryOutField, postProcessField] {
            f.cell?.lineBreakMode = .byTruncatingHead
            f.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
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
        ppModePopup.addItems(withTitles: ppModeTitles)
        ppModePopup.target = self; ppModePopup.action = #selector(ppModeChanged)
        runnerPopup.addItems(withTitles: runnerTitles)
        openaiBaseField.placeholderString = "empty = api.openai.com"

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
        summaryChooseBtn = NSButton(title: "Choose…", target: self, action: #selector(chooseSummaryDir))
        let summaryStack = NSStackView(views: [summaryOutField, summaryChooseBtn!]); summaryStack.orientation = .horizontal; summaryStack.spacing = 6

        // Grouped into tabs (each pane stays short) instead of one long scrolling form.
        func row(_ label: String, _ control: NSView) -> [NSView] { [labeled(label), control] }
        // Section header (semibold + SF Symbol, spans both columns) and field caption (small gray hint
        // under a field) — the grouping vocabulary for denser tabs. The icon is what makes sections
        // read as sections at a glance; it matches the TEXT color (user feedback: the accent-blue
        // version read poorly — tinted icons look like links, and contrast suffered in dark mode).
        // Row ROLES are carried by marker types (SectionHeaderCell / CaptionCell) and derived by
        // formRowRoles — the old hand-maintained index lists went stale the moment rows were inserted
        // (regression: the Post-process tab shipped with a field row merged as a header).
        func sectionHeader(_ s: String, symbol: String? = nil) -> [NSView] {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 13, weight: .semibold)
            var content: [NSView] = [l]
            if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let iv = NSImageView(image: img)
                iv.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
                iv.contentTintColor = .labelColor
                iv.setContentHuggingPriority(.required, for: .horizontal)
                content = [iv, l]
            }
            let st = SectionHeaderCell(views: content)
            st.orientation = .horizontal; st.spacing = 6; st.alignment = .centerY
            return [st, NSView()]
        }
        func captionLabel(_ s: String, width: CGFloat) -> CaptionCell {
            let l = CaptionCell(wrappingLabelWithString: s)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.preferredMaxLayoutWidth = width
            return l
        }
        func fieldCaption(_ s: String) -> [NSView] { [labeled(""), captionLabel(s, width: 340)] }
        func sectionNote(_ s: String) -> [NSView] { [captionLabel(s, width: 440), NSView()] }   // full-width via role derivation
        /// Headers (section titles / full-width intro notes) merge both columns with extra air above;
        /// captions pull tight under the field they describe. Roles are DERIVED from the row's views
        /// (see formRowRoles) — nothing to renumber when rows are inserted.
        func tab(_ title: String, _ rows: [[NSView]]) -> NSTabViewItem {
            let grid = NSGridView(views: rows)
            grid.translatesAutoresizingMaskIntoConstraints = false
            grid.rowSpacing = 9; grid.columnSpacing = 18
            grid.column(at: 0).xPlacement = .trailing
            let roles = formRowRoles(rows)
            for r in roles.headers {
                grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2),
                                verticalRange: NSRange(location: r, length: 1))
                grid.cell(atColumnIndex: 0, rowIndex: r).xPlacement = .leading
                if r > 0 { grid.row(at: r).topPadding = 14 }
            }
            for r in roles.notes { grid.row(at: r).topPadding = -5 }
            // The grid lives in a SCROLLABLE pane: a tab taller than the window must scroll, never clip
            // (regression: the Post-process rows sat unreachable below the window edge).
            let doc = FlippedDocView()   // flipped so the form starts at the TOP of the scroll area
            doc.translatesAutoresizingMaskIntoConstraints = false
            doc.addSubview(grid)
            let scroll = NSScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.documentView = doc
            let pane = NSView(); pane.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: pane.topAnchor),
                scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
                doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                grid.topAnchor.constraint(equalTo: doc.topAnchor, constant: 20),
                grid.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
                grid.leadingAnchor.constraint(greaterThanOrEqualTo: doc.leadingAnchor, constant: 24),
                grid.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -20),   // content sets doc height → scrolls
            ])
            let item = NSTabViewItem(); item.label = title; item.view = pane
            return item
        }

        let tabs = NSTabView(); tabs.translatesAutoresizingMaskIntoConstraints = false
        tabsForTest = tabs
        tabs.focusRingType = .none   // clicking a tab otherwise shows a blue focus ring on top of the tab highlight ("double blue")
        tabs.addTabViewItem(tab("Recording", [
            row("Segment length (on the hour):", segPopup),
            row("", systemAudioBtn),
            row("", echoBtn),
            row("Min. speech (sec):", voiceField),
            row("", vadBtn),
            row("Excluded apps:", excludeTokens),
            row("Add a running app:", addAppPopup),
            // Storage lives here too (user pick: what gets recorded and where it lands is one story).
            sectionHeader("Transcripts", symbol: "doc.text"),
            row("Keep for:", txtRetPopup),
            row("Save to:", dirStack),
            sectionHeader("Audio", symbol: "waveform"),
            row("", keepAudioBtn),
            row("Compress after:", audioRawCombo),
            fieldCaption("Recent recordings stay WAV; older ones are archived to AAC (~⅛ the size). "
                       + "Type any period — 45 days, 6 months, 1 year."),
            row("Delete after:", audioRetCombo),
            fieldCaption("Audio older than this is deleted, raw or compressed. Unlimited keeps it forever."),
            row("Save to:", audioStack),
        ]))
        tabs.addTabViewItem(tab("Schedule", [
            row("", schedBtn),
            row("Days:", schedDaysField),
            fieldCaption("mon-fri, or a list like mon,wed,fri. Empty = every day."),
            row("Hours:", schedHoursField),
            fieldCaption("Ranges like 10:00-12:00, 13:00-19:00 — the gap between ranges is your "
                       + "lunch break. 22:00-06:00 wraps past midnight. Empty = all hours. "
                       + "Unparseable input turns red and is ignored."),
            fieldCaption("Off-hours the tray shows ⏸ Off-hours (schedule). A manual Pause/Resume "
                       + "overrides the schedule until its next boundary."),
        ]))
        tabs.addTabViewItem(tab("Transcription", [
            row("Model:", modelPopup),                                                            // 0
            row("…or custom model:", customModelField),                                           // 1
            row("Language:", langPopup),                                                          // 2
            fieldCaption("The spoken language whisper transcribes."),                             // 3
            row("Transcript file language:", transcriptLangPopup),                                // 4
            fieldCaption("Headings and labels of the saved markdown file (not the speech)."),     // 5
            sectionHeader("Hints", symbol: "character.book.closed"),                              // 6
            row("Terms:", hintsTermsField),                                                       // 7
            fieldCaption("Team/product names, jargon, people — comma or newline separated. "
                       + "Biases recognition so proper nouns stop coming out mangled."),          // 8
            row("…or hints file:", hintsFileField),                                               // 9
            fieldCaption("One term per line, # comments — merged with the terms above."),         // 10
            row("", hintsCalBtn),                                                                 // 11
        ]))
        tabs.addTabViewItem(tab("Post-process", [
            sectionNote("Runs after each hourly transcript is saved."),                           // 0
            row("Mode:", ppModePopup),                                                            // 1
            fieldCaption("Automatic summary is built in — pick who writes it; or take full "
                       + "control with a custom command."),                                       // 2
            sectionHeader("Automatic summary", symbol: "wand.and.stars"),                                                   // 3
            row("Summarize with:", runnerPopup),                                                  // 4
            row("Prompt:", promptScroll),                                                         // 5
            fieldCaption("Default asks for key points, decisions, and action items — answered "
                       + "in the transcript's language."),                                        // 6
            row("…or prompt file:", promptFileField),                                             // 7
            fieldCaption("Overrides the text above when readable — keep the prompt in your "
                       + "notes repo and iterate without opening Settings."),                     // 8
            row("Save summary to:", summaryStack),                                                // 9
            fieldCaption("Folder for <name>.summary.md. Empty = next to the transcript."),        // 10
            sectionHeader("Custom command", symbol: "terminal"),                                  // 11
            row("Command:", postProcessField),                                                    // 12
            fieldCaption("Freeform: runs in a login shell with the transcript path appended "
                       + "as the last argument."),                                                // 13
        ]))
        tabs.addTabViewItem(tab("Titling", [
            row("", calBtn),
            row("Calendars:", calListCell),
        ]))
        tabs.addTabViewItem(tab("Live", [
            sectionNote("Cloud caption engines stream audio off-device — only while the live overlay "
                      + "runs with that engine selected. Keys are stored in the Keychain, never in "
                      + "preferences or backups. Pick the engine in the overlay's control bar."),    // 0
            sectionHeader("Deepgram", symbol: "cloud"),                                                             // 1
            row("API key:", deepgramKeyField),                                                       // 2
            fieldCaption("Get a key at console.deepgram.com (model: nova-2)."),                      // 3
            sectionHeader("OpenAI", symbol: "sparkles"),                                                               // 4
            row("API key:", openaiKeyField),                                                         // 5
            fieldCaption("platform.openai.com — or a key your gateway accepts (gpt-4o-transcribe)."), // 6
            row("Base URL:", openaiBaseField),                                                       // 7
            fieldCaption("OpenAI-compatible gateway / corporate proxy. Leave empty for api.openai.com."), // 8
            sectionHeader("Gladia", symbol: "waveform.circle"),                                      // 9
            row("API key:", gladiaKeyField),                                                         // 10
            fieldCaption("app.gladia.io — broad language coverage incl. Korean streaming."),         // 11
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

    /// Only the fields the selected mode actually uses are editable — the form reads as one choice.
    @objc private func ppModeChanged() { updatePostProcessEnabled() }
    private func updatePostProcessEnabled() {
        let mode = PostProcessMode(rawValue: ppModeValues[max(0, ppModePopup.indexOfSelectedItem)]) ?? .off
        for c in [runnerPopup, summaryOutField] as [NSControl] { c.isEnabled = mode == .summary }
        summaryChooseBtn?.isEnabled = mode == .summary
        promptFileField.isEnabled = mode == .summary
        promptView.isEditable = mode == .summary
        promptScroll.alphaValue = mode == .summary ? 1 : 0.45   // NSTextView isn't an NSControl — dim to match
        postProcessField.isEnabled = mode == .shell
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
        deepgramKeyField.stringValue = DeepgramLiveTranscriber.storedKey ?? ""   // migrates legacy prefs too
        openaiKeyField.stringValue = OpenAILiveTranscriber.storedKey ?? ""
        gladiaKeyField.stringValue = GladiaLiveTranscriber.storedKey ?? ""
        openaiBaseField.stringValue = OpenAILiveTranscriber.configuredBase   // explicit save (even "") beats env
        postProcessField.stringValue = Pref.postProcessCommand               // same explicit-save semantics
        // Show the EFFECTIVE mode (incl. the v1 migration: unset mode + v1 command = Custom command) —
        // displaying Off while a hook is live would let Save silently kill it.
        ppModePopup.selectItem(at: idx(effectivePostProcessMode(
            rawMode: Pref.explicit(Pref.postProcessMode, "MR_POST_PROCESS_MODE"),
            shellCmd: Pref.postProcessCommand).rawValue, ppModeValues))
        runnerPopup.selectItem(at: idx(Pref.explicit(Pref.summaryRunner, "MR_SUMMARY_RUNNER"), runnerValues))
        let savedPrompt = Pref.explicit(Pref.summaryPrompt, "MR_SUMMARY_PROMPT")
        promptView.string = savedPrompt.isEmpty ? defaultSummaryPrompt : savedPrompt   // show the editable default
        promptFileField.stringValue = Pref.explicit(Pref.summaryPromptFile, "MR_SUMMARY_PROMPT_FILE")
        summaryOutField.stringValue = Pref.explicit(Pref.summaryOut, "MR_SUMMARY_OUT")
        hintsTermsField.stringValue = Pref.explicit(Pref.hintsTerms, "MR_HINTS")
        hintsFileField.stringValue = Pref.explicit(Pref.hintsFile, "MR_HINTS_FILE")
        hintsCalBtn.state = Pref.bool(Pref.hintsCalendar, "MR_HINTS_CALENDAR", false) ? .on : .off
        schedBtn.state = Pref.bool(Pref.schedEnabled, "MR_SCHEDULE", false) ? .on : .off
        schedDaysField.stringValue = Pref.explicit(Pref.schedDays, "MR_SCHEDULE_DAYS")
        schedHoursField.stringValue = Pref.explicit(Pref.schedHours, "MR_SCHEDULE_HOURS")
        recolorScheduleFields()
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

    @objc private func chooseDir() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { dirField.stringValue = u.path }
    }
    @objc private func chooseAudioDir() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { audioDirField.stringValue = u.path }
    }
    @objc private func chooseSummaryDir() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { summaryOutField.stringValue = u.path }
    }

    @objc private func saveAndClose() {
        // Keychain first — if a credential write fails, abort BEFORE touching any other setting so
        // the user isn't left with a half-saved state (and no key is silently lost). All-or-nothing:
        // keys saved earlier in the loop are rolled back (best effort) on a later failure.
        let creds = [("deepgram", deepgramKeyField, "Deepgram"), ("openai", openaiKeyField, "OpenAI"),
                     ("gladia", gladiaKeyField, "Gladia")]
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
        d.set(ppModeValues[max(0, ppModePopup.indexOfSelectedItem)], forKey: Pref.postProcessMode)
        d.set(runnerValues[max(0, runnerPopup.indexOfSelectedItem)], forKey: Pref.summaryRunner)
        d.set(promptView.string.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.summaryPrompt)
        d.set(promptFileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.summaryPromptFile)
        d.set(summaryOutField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.summaryOut)
        d.set(hintsTermsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.hintsTerms)
        d.set(hintsFileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.hintsFile)
        d.set(hintsCalBtn.state == .on, forKey: Pref.hintsCalendar)
        d.set(schedBtn.state == .on, forKey: Pref.schedEnabled)
        d.set(schedDaysField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.schedDays)
        d.set(schedHoursField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.schedHours)
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
/// "_자동 생성. 재사용할 지식은 topics/로 정제하세요._" is intentionally GONE: the app has no
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
    case apple, whisper, deepgram, openai, gladia
    static var current: LiveEngine { LiveEngine(rawValue: Pref.d.string(forKey: Pref.liveEngine) ?? "") ?? .apple }
    var title: String {
        switch self {
        case .apple:    return "Apple"
        case .whisper:  return "Whisper"
        case .deepgram: return "Deepgram ☁"
        case .openai:   return "OpenAI ☁"
        case .gladia:   return "Gladia ☁"
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
    private var controlsAccessory: NSTitlebarAccessoryViewController?   // the full control strip (collapsible)
    private let collapseBtn = NSButton()                                // chevron RIGHT NEXT TO the title text
    private var chevronLead: NSLayoutConstraint?                        // titlebar.centerX + titleWidth/2 + gap
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
        panel = CaptionPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 172),   // default fits one more caption line
                             styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        super.init()
        panel.title = "\(Self.titleIcon) macrec live"
        panel.alphaValue = CGFloat(min(1.0, max(0.3, Pref.dbl(Pref.liveOpacity, "MR_LIVE_OPACITY", 1.0))))
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
            spacer, copyBtn, aMinus, aPlus, tsToggle, opacity])
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
    /// Copy the current selection — or the whole transcript when nothing is selected.
    @objc private func copyTranscript() {
        let sel = textView.selectedRange()
        let text = (sel.length > 0 ? (textView.string as NSString).substring(with: sel) : textView.string)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
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
    return nil
}

enum Notifier {
    static func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, err in
            elog("notify: authorization granted=\(granted)\(err.map { " error=\($0)" } ?? "")")
        }
    }
    /// filePath rides in userInfo; clicking the notification opens it (AppController is the delegate).
    static func push(title: String, body: String, filePath: String? = nil) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        if let filePath { c.userInfo = ["file": filePath] }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        ) { err in if let err { elog("notify: add failed: \(err)") } }
    }
}

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var engine: RecordingEngine?
    private var stopTask: Task<Void, Never>?   // in-flight engine stop (pause) — resume/restart await it so
                                               // two capture pipelines never overlap on the shared audio state
    private var voiceTimer: Timer?             // ~1 Hz poll for the voice-activity tray tint
    private var schedTimer: Timer?             // ~30 s recording-schedule enforcement
    private var notifyWhenTranscribed = false  // armed by "Transcribe now" — the menu closed, push the outcome
    private var lastTranscriptURL: URL?        // most recent saved transcript (notification click opens it)
    private let traySpinner = NSProgressIndicator()   // menu-bar spinner while a manual flush transcribes
    private var trayBusy = false               // spinner owns the tray — setIcon() must not repaint over it
    private var trayBusyGeneration = 0         // failsafe-timeout token (a new flush invalidates old timers)
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
        let vt = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.pollVoice() }
        RunLoop.main.add(vt, forMode: .common)   // .common so the tint updates while menus track too
        voiceTimer = vt
        let st = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.checkSchedule() }   // timer runs in .common; engine state is main-confined
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
        guard !trayBusy else { return }   // the flush spinner owns the tray until the outcome lands
        // Distinct audio-recorder identity: a waveform-with-mic while live, pause when not. While
        // VOICE is being picked up, the glyph tints a LIGHT orange — the recording color, softened
        // (user pick after trying full orange → accent → this: orange family, but lighter).
        let primary = recording ? "waveform.badge.mic" : "pause.circle"
        let fallback = recording ? "waveform" : "pause"
        // Fixed point size so the menu-bar icon never resizes (independent of which symbol).
        var cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        if voice {
            let lightOrange = NSColor.systemOrange.blended(withFraction: 0.35, of: .white) ?? .systemOrange
            cfg = cfg.applying(.init(paletteColors: [lightOrange]))
        }
        let img = (NSImage(systemSymbolName: primary, accessibilityDescription: "macrec")
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: "macrec"))?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = !voice   // template adapts to the menu bar; the voice tint must keep its color
        statusItem.button?.image = img
        // Hug the glyph's real width (+ a hair) so there's no wide L/R slack — WITHOUT touching pointSize
        // or imagePosition (fixed length keeps the vertical centering that variableLength/imageOnly broke).
        let glyphW = img?.size.width ?? 22
        statusItem.length = ceil(glyphW) + 4
        if Pref.bool("trayDebug", "MR_TRAY_DEBUG", false) {
            elog("icon set (recording=\(recording), voice=\(voice)), glyphW=\(glyphW), length=\(statusItem.length)")
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
        // Transcribe now — a NATIVE item (user pick: closing the menu on click feels right, and it
        // brings back AppKit's own hover/highlight/keyboard handling). The outcome that used to be
        // watched in the open menu arrives as a notification instead (see flushOutcome/Notifier).
        menu.addItem(item("Transcribe now", #selector(flushNow), symbol: "doc.badge.plus"))
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
        guard engine != nil, !paused else { return }
        notifyWhenTranscribed = true   // menu just closed — deliver the outcome as a push
        Notifier.requestAuth()         // no-op after the user answered the first prompt
        showTraySpinner()              // …and show progress right where the user just clicked
        engine?.flushNow()
        refresh("● Transcribing now…")
    }

    /// One push per armed "Transcribe now": the first TERMINAL status (saved / no speech / failed)
    /// consumes the flag; intermediate ones ("Transcribing…") don't.
    private func pushFlushOutcomeIfNeeded(_ status: String) {
        guard notifyWhenTranscribed, let o = flushOutcome(for: status) else { return }
        notifyWhenTranscribed = false
        hideTraySpinner()
        let file = status.hasPrefix("Saved: ") ? lastTranscriptURL?.path : nil
        Notifier.push(title: o.title, body: o.body, filePath: file)
    }

    /// Swap the tray glyph for a small indeterminate spinner while the manual flush transcribes —
    /// the menu closed on click, so this is the only in-place progress the user can see.
    private func showTraySpinner() {
        guard !trayBusy, let btn = statusItem.button else { return }
        trayBusy = true
        trayBusyGeneration += 1
        traySpinner.style = .spinning
        traySpinner.controlSize = .small
        traySpinner.isIndeterminate = true
        traySpinner.isDisplayedWhenStopped = false
        traySpinner.frame = NSRect(x: (btn.bounds.width - 16) / 2, y: (btn.bounds.height - 16) / 2,
                                   width: 16, height: 16)
        btn.image = nil
        btn.addSubview(traySpinner)
        traySpinner.startAnimation(nil)
        // Failsafe: whisper on a long segment takes minutes, but a lost outcome (engine swapped out
        // mid-flush) must not leave the tray spinning forever.
        let gen = trayBusyGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 15 * 60) { [weak self] in
            guard let self, self.trayBusy, self.trayBusyGeneration == gen else { return }
            elog("tray: flush spinner timed out — restoring the icon")
            self.hideTraySpinner()
        }
    }

    private func hideTraySpinner() {
        guard trayBusy else { return }
        trayBusy = false
        traySpinner.stopAnimation(nil)
        traySpinner.removeFromSuperview()
        setIcon(recording: engine != nil && !paused && !schedulePaused)
    }

    @objc private func togglePause() {
        // A manual choice beats the schedule until the next boundary — stored as the boundary's
        // TIMESTAMP so it still expires when the Mac slept across it (nil = schedule never flips).
        scheduleOverrideUntil = RecordSchedule.fromPrefs.nextBoundary(after: Date())
        schedulePaused = false
        if paused {
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
        if let p = response.notification.request.content.userInfo["file"] as? String {
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
                                          + "> '/t/a b'\\''s.summary.md.partial' "
                                          + "&& mv '/t/a b'\\''s.summary.md.partial' '/t/a b'\\''s.summary.md'")
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
                  summaryOutputPath(transcriptPath: "/t/x.md", outDir: "") == "/t/x.summary.md"
                  && summaryOutputPath(transcriptPath: "/t/x.md", outDir: "~/sums")
                     == (("~/sums" as NSString).expandingTildeInPath + "/x.summary.md"))
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
            if let tv = sw.tabsForTest {
                let allScroll = tv.tabViewItems.allSatisfy { item in
                    item.view?.subviews.contains { ($0 as? NSScrollView)?.documentView != nil } ?? false
                }
                check("settings: every tab pane scrolls (rows can never be clipped away)", allScroll)
                check("settings: Post-process is its own tab",
                      tv.tabViewItems.contains { $0.label == "Post-process" })
                check("settings: Schedule is its own tab",
                      tv.tabViewItems.contains { $0.label == "Schedule" })
                // Layout regression (user-reported: Post-process UI broke): every merged row must be a
                // marker-typed header/note — a stale hand-kept index list once merged a real field row
                // ("Save summary to") into a section header, destroying its label+control layout.
                var intact = true
                for item in tv.tabViewItems {
                    guard let grid = firstGrid(in: item.view) else { intact = false; continue }
                    for r in 0..<grid.numberOfRows {
                        let c0 = grid.cell(atColumnIndex: 0, rowIndex: r).contentView
                        let merged = grid.numberOfColumns > 1
                            && grid.cell(atColumnIndex: 1, rowIndex: r).contentView === c0
                        let isRoleRow = c0 is SectionHeaderCell || c0 is CaptionCell
                        if merged && !isRoleRow { intact = false }   // a field row got eaten by a header merge
                    }
                }
                check("settings: only role-marked rows are merged (no field row eaten)", intact)
            } else {
                check("settings: tabs built for inspection", false)
            }
            // Role derivation is pure — headers from marker col-0, notes from marker col-1, fields plain.
            let rolesProbe = formRowRoles([[SectionHeaderCell(), NSView()], [NSView(), NSView()],
                                           [NSView(), CaptionCell(labelWithString: "c")],
                                           [CaptionCell(labelWithString: "n"), NSView()]])
            check("settings: form row roles derived from markers",
                  rolesProbe.headers == [0, 3] && rolesProbe.notes == [2])
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
            // Transcribe-now push: terminal statuses notify (menu closes on click now), transient
            // ones keep waiting — a dangling flag would mis-attribute the NEXT hourly segment.
            check("flush push: terminal statuses classified, transient ones wait",
                  flushOutcome(for: "Saved: 2026-07-05-2100-2130.md")! == ("Transcript ready", "2026-07-05-2100-2130.md")
                  && flushOutcome(for: "No speech — discarded") != nil
                  && flushOutcome(for: "No speech — skipped") != nil
                  && flushOutcome(for: "Downloading model — transcription deferred") != nil
                  && flushOutcome(for: "Transcription failed") != nil
                  && flushOutcome(for: "Transcribing…") == nil
                  && flushOutcome(for: "Recording · mic + system audio") == nil
                  && flushOutcome(for: "Paused (locked/asleep)") == nil)
            // File naming: start + END time, so a mid-hour "Transcribe now" shows the cut point.
            check("naming: transcript base carries start AND end times",
                  transcriptBaseName(start: schedDate("2026-07-05 21:00"), end: schedDate("2026-07-05 21:30"),
                                     timeZone: utc.timeZone) == "2026-07-05-2100-2130"
                  && transcriptBaseName(start: schedDate("2026-07-05 23:50"), end: schedDate("2026-07-06 00:20"),
                                        timeZone: utc.timeZone) == "2026-07-05-2350-0020")   // keeps start's date
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
