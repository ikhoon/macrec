import Foundation

// The eval RUNNER's pure core: score STT engines over ko/ja samples and format a leaderboard. The
// actual transcription (Whisper/Apple + audio) is injected as a `transcribe` closure, so the
// orchestration, the corpus micro-average, and the table are selftestable without audio/engine/network.

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

/// Score each engine over the samples: transcribe each, sum edits and reference chars, then take the
/// corpus CER = Σ edits / Σ N (micro-average). An empty corpus (no reference text) scores 0 when the
/// engine also stays silent, 1 when it invents text. Pure given `transcribe`; results sorted best-first.
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
    .sorted { $0.cer < $1.cer }
}

/// A fixed-width leaderboard — engines best-CER first, CER as a percentage. `title` heads the table.
func evalReport(_ scores: [EngineScore], title: String = "ko/ja STT — CER (lower is better)") -> String {
    guard !scores.isEmpty else { return "\(title)\n(no engines scored)" }
    let w = max(6, scores.map { $0.engine.count }.max() ?? 6)
    func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: max(n, s.count), withPad: " ", startingAt: 0) }
    var lines = [title, "", "\(pad("engine", w))   CER      n"]
    for s in scores {
        lines.append("\(pad(s.engine, w))   \(pad(String(format: "%.1f%%", s.cer * 100), 7))  \(s.samples)")
    }
    return lines.joined(separator: "\n")
}
