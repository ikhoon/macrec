import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

// MARK: - recorder (holds the per-source writers)

final class Recorder {
    var sysWriter: SourceWriter?
    var micWriter: SourceWriter?
    /// Set by CaptureSession when a full-mix reference tap is feeding the canceller instead. This tap is
    /// the transcript's filtered mix, which omits excluded apps and must NOT be the AEC reference then.
    var referenceComesFromFullMixTap = false
    let queue = DispatchQueue(label: "macrec.audio")

    init(sysWriter: SourceWriter?, micWriter: SourceWriter?) {
        self.sysWriter = sysWriter
        self.micWriter = micWriter
    }

    /// System audio arrives from the Core Audio tap (an owned copy — safe to hand to the queue).
    /// Live captions are fed straight from here (lowest latency — no WAV-write/canon-convert/queue hop).
    func appendSys(_ buf: AVAudioPCMBuffer) {
        // Feed the AEC reference only when the full-mix tap ISN'T (this filtered mix drops excluded apps).
        if EchoCanceller.shared.enabled && !referenceComesFromFullMixTap { EchoCanceller.shared.pushReference(buf) }
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
        queue.sync {}
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
