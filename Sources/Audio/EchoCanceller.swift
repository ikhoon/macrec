import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
#if SWIFT_PACKAGE
    import CSpeexDSP // swift build: speex symbols via the C module; the swiftc build uses speex-bridge.h
#endif

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
