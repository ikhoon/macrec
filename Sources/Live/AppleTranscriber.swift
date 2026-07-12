import AppKit
import AVFoundation
import Foundation
import Speech
import Translation

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
