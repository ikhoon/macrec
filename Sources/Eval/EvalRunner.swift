import Foundation

// The eval RUNNER's pure core. Transcription (Whisper/Apple + audio) is injected as a `transcribe`
// closure, so the orchestration, corpus micro-average, and report are testable without audio/network.

/// A reference sample: an id, its language ("ja"/"ko" — picks the normalizer), and the ground-truth text.
struct EvalSample: Equatable {
    let id: String
    let language: String
    let reference: String
}

/// One engine's aggregate over the samples it was scored on. `cer` is the corpus micro-average.
struct EngineScore: Equatable {
    let engine: String
    let cer: Double
    let samples: Int
}

/// Edit count + reference length for one hyp/ref pair, so the runner can micro-average across samples
/// (a mean of per-file CER over-weights short utterances). Picks the ko or ja normalizer by `language`.
func cerParts(hyp: String, ref: String, language: String) -> (edits: Int, refCount: Int) {
    let ko = language.lowercased().hasPrefix("ko")
    let r = ko ? normalizeKo(ref) : normalizeJa(ref)
    let h = ko ? normalizeKo(hyp) : normalizeJa(hyp)
    return (levenshtein(h, r), r.count)
}

/// Score each engine over the samples: corpus CER = Σ edits / Σ N (micro-average). CER is UNBOUNDED —
/// an empty-reference sample the engine hallucinates into adds its insertions to Σ edits but 0 to Σ N,
/// so a corpus with hallucinated silence can exceed 1.0 (correct: inventing text on silence is error).
/// A wholly-empty corpus (Σ N = 0) → 0 if every engine stayed silent, 1 if any invented text. Ties
/// break by engine name so the leaderboard is deterministic. Pure given `transcribe`.
func runEval(samples: [EvalSample], engines: [String],
             transcribe: (EvalSample, String) -> String) -> [EngineScore] {
    engines.map { engine -> EngineScore in
        var edits = 0, refChars = 0
        for s in samples {
            let p = cerParts(hyp: transcribe(s, engine), ref: s.reference, language: s.language)
            edits += p.edits
            refChars += p.refCount
        }
        let cer = refChars > 0 ? Double(edits) / Double(refChars) : (edits > 0 ? 1 : 0)
        return EngineScore(engine: engine, cer: cer, samples: samples.count)
    }
    .sorted { $0.cer != $1.cer ? $0.cer < $1.cer : $0.engine < $1.engine }
}

/// A fixed-width leaderboard — engines best-CER first, CER as a percentage. `title` heads the table.
func evalReport(_ scores: [EngineScore], title: String = "ko/ja STT — CER (lower is better)") -> String {
    guard !scores.isEmpty else { return "\(title)\n(no engines scored)" }
    let w = max(6, scores.map { $0.engine.count }.max() ?? 6)
    let posix = Locale(identifier: "en_US_POSIX")   // fixed decimal separator — never "33,3%" on comma locales
    func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: max(n, s.count), withPad: " ", startingAt: 0) }
    var lines = [title, "", "\(pad("engine", w))   CER      n"]
    for s in scores {
        lines.append("\(pad(s.engine, w))   \(pad(String(format: "%.1f%%", locale: posix, s.cer * 100), 7))  \(s.samples)")
    }
    return lines.joined(separator: "\n")
}
