import AppKit
import AVFoundation
import Compression
import EventKit
import Foundation

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
