// Audio capture and processing: the per-source writers, the mixdown, the SpeexDSP echo canceller,
// the recorder that owns them, the default-output guard, and the microphone capture session.
//
// Nothing here touches AppKit or the transcript pipeline — it produces WAVs and levels, nothing more.

import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

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
