import AppKit
import AVFoundation
import EventKit
import Foundation
#if SWIFT_PACKAGE
    import CSpeexDSP // swift build: speex symbols via the C module; the swiftc build uses speex-bridge.h
#endif

func audioSelftests(_ check: (String, Bool) -> Void) {
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
    // AEC reference gating (#29): when the dedicated full-mix reference tap is live, appendSys must
    // NOT also push the filtered mix as reference — a double feed corrupts the FIFO pairing the AEC
    // relies on. This is the seam the shouldStartReferenceTap decision test can't see (that's the
    // *choice*; this is the *wiring* that honors it).
    Pref.d.set(true, forKey: Pref.echoReduce)
    EchoCanceller.shared.reset()
    let gateRec = Recorder(sysWriter: nil, micWriter: nil)
    gateRec.referenceComesFromFullMixTap = true       // full-mix tap owns the reference…
    let gateBase = EchoCanceller.shared.refDepthForTest
    gateRec.appendSys(ecBuf(256))
    let gatedOff = EchoCanceller.shared.refDepthForTest == gateBase     // …so appendSys pushes nothing
    gateRec.referenceComesFromFullMixTap = false      // no full-mix tap → the filtered mix IS the reference
    gateRec.appendSys(ecBuf(256))
    let gatedOn = EchoCanceller.shared.refDepthForTest > gateBase       // …so appendSys pushes it
    Pref.d.removeObject(forKey: Pref.echoReduce)
    EchoCanceller.shared.reset()
    check("AEC reference gating: live full-mix tap suppresses the filtered-mix reference push", gatedOff && gatedOn)
    // Writer ↔ reference speech accounting must never drift. speechlikeFrames is what the fixture
    // tests pin; SourceWriter.append is what production runs — and the incident class is exactly
    // "state across buffer boundaries", so the writer gets the SAME signal in irregular chunk sizes
    // (nothing 256-aligned) and must land within one envelope block of the reference.
    do {
        var sig: [Float] = []
        for burst in 0..<3 {   // three utterances with gaps, then isolated pops
            sig += (0..<11200).map { sinf(Float(burst * 11200 + $0) * 0.13) * 0.3 }   // 700 ms on
            sig += [Float](repeating: 0, count: 6400)                                 // 400 ms off
        }
        sig += (0..<16000).map { $0 % 3200 == 0 ? 0.9 : 0.0 }
        let expect = Double(speechlikeFrames(sig)) / 16000
        let swURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-sync-\(UUID().uuidString).wav")
        var agreed = false
        if let sw = try? SourceWriter(url: swURL) {
            var i = 0, c = 0
            let chunks = [173, 480, 997, 31, 1024, 555]
            while i < sig.count {
                let n = min(chunks[c % chunks.count], sig.count - i)
                c += 1
                let b = AVAudioPCMBuffer(pcmFormat: ecFmt, frameCapacity: AVAudioFrameCount(n))!
                b.frameLength = AVAudioFrameCount(n)
                for j in 0..<n { b.floatChannelData![0][j] = sig[i + j] }
                sw.append(b)
                i += n
            }
            agreed = abs(sw.speechSeconds - expect) <= 0.017 && expect > 1.5
        }
        try? FileManager.default.removeItem(at: swURL)
        check("writer ↔ reference: envelope accounting agrees across irregular buffer boundaries", agreed)
    }
    // tap-probe verdict — the 2026-07-15 numbers: a healthy tap measured 0 buffers in silence (the
    // probe's first version called that "aggregate not running") and 369 buffers / peak 0.14 with a
    // tone playing. Zero buffers may only condemn the tap when the probe KNOWS its tone played.
    check("tap-probe verdict: silence is inconclusive, tone-and-nothing is dead, zeros are muted",
          tapProbeVerdict(buffers: 369, peak: 0.1422, tonePlayed: true).code == 0     // the healthy tap
          && tapProbeVerdict(buffers: 0, peak: 0, tonePlayed: false).code == 4        // silence ≠ dead
          && tapProbeVerdict(buffers: 0, peak: 0, tonePlayed: true).code == 2         // tone played, nothing came
          && tapProbeVerdict(buffers: 300, peak: 0.0, tonePlayed: true).code == 3     // the tap-mute P0 shape
          && tapProbeVerdict(buffers: 0, peak: 0, tonePlayed: true).line.contains("test tone"))
}
