import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

// MARK: - microphone capture (separate AVCaptureSession — does NOT touch the output device)

/// Captures the microphone via AVCaptureSession, delivering audio frames to a callback for recording.
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
