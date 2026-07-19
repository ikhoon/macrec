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

// MARK: - corpus + engine plumbing for the `macrec eval` subcommand (pure; the shell layer injects IO)

/// One corpus clip on disk: "<id>.<lang>.wav" with an optional "<id>.<lang>.txt" ground truth.
/// A clip without a reference is still transcribed (its hypotheses are dumped for the human to
/// correct INTO a reference) — it just can't be CER-scored yet.
struct EvalClip: Equatable {
    let id: String
    let language: String
    let wav: String // file name, not path — the caller owns the directory
    let reference: String?
}

/// Discover clips from a directory listing: `<id>.<ko|ja>.wav`, reference read via `read` (nil =
/// missing/empty). Junk names are skipped. Parsing slices around the LAST dots — never a global
/// substring replace and never a component split that collapses empties — so an id containing
/// ".wav" or consecutive dots keeps a lossless id and a correctly-derived reference name
/// (review round: the old global ".wav"→".txt" replace silently unscored such clips).
func evalCorpus(names: [String], read: (String) -> String?) -> [EvalClip] {
    names.filter { $0.hasSuffix(".wav") }.compactMap { wav -> EvalClip? in
        let stem = String(wav.dropLast(4))
        guard let dot = stem.lastIndex(of: ".") else { return nil }
        let lang = String(stem[stem.index(after: dot)...])
        let id = String(stem[..<dot])
        guard !id.isEmpty, ["ko", "ja"].contains(lang) else { return nil }
        let ref = read(stem + ".txt")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return EvalClip(id: id, language: lang, wav: wav, reference: (ref?.isEmpty ?? true) ? nil : ref)
    }
    .sorted { $0.id != $1.id ? $0.id < $1.id : $0.language < $1.language }
}

/// "--engine name=cmd … {wav} …" → (name, template). The command must print the transcript to
/// stdout; {wav} is replaced with the clip's absolute path. Names are path-safe identifiers
/// ([A-Za-z0-9._-], no separators) because they become out/ file names. nil when malformed.
func parseEngineSpec(_ s: String) -> (name: String, template: String)? {
    guard let eq = s.firstIndex(of: "=") else { return nil }
    let name = String(s[..<eq]).trimmingCharacters(in: .whitespaces)
    let template = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, template.contains("{wav}"),
          name.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) })
    else { return nil }
    return (name, template)
}

/// Substitute the language code and the clip path (shell-quoted) into an engine template —
/// {lang} FIRST, so a pathological "{lang}" inside the substituted path is never rewritten.
func evalCommand(template: String, wav: String, lang: String) -> String {
    template.replacingOccurrences(of: "{lang}", with: lang)
        .replacingOccurrences(of: "{wav}", with: shq(wav))
}

/// Speed table: total wall seconds per engine and RTF (audio seconds ÷ wall seconds — higher is
/// faster; 1.0 = real time).
func evalTimingReport(_ rows: [(engine: String, seconds: Double, audioSeconds: Double)]) -> String {
    guard !rows.isEmpty else { return "(no timings)" }
    let w = max(6, rows.map { $0.engine.count }.max() ?? 6)
    let posix = Locale(identifier: "en_US_POSIX")
    func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: max(n, s.count), withPad: " ", startingAt: 0) }
    var lines = ["speed — \(String(format: "%.0f", locale: posix, rows.first?.audioSeconds ?? 0)) s of audio (RTF = audio÷wall; higher is faster)", "",
                 "\(pad("engine", w))   wall     RTF"]
    for r in rows.sorted(by: { $0.seconds < $1.seconds }) {
        let rtf = r.seconds > 0 ? r.audioSeconds / r.seconds : 0
        lines.append("\(pad(r.engine, w))   \(pad(String(format: "%.1fs", locale: posix, r.seconds), 7))  \(String(format: "%.1f×", locale: posix, rtf))")
    }
    return lines.joined(separator: "\n")
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
