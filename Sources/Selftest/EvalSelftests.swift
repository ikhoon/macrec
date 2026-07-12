import Foundation

func evalSelftests(_ check: (String, Bool) -> Void) {
    // CER (Character Error Rate) — the CJK-standard STT metric. Values pinned from real ko/ja pairs.
    func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
    check("cer: identical → 0", cerJa(hyp: "会議を始めましょう", ref: "会議を始めましょう") == 0
          && cerKo(hyp: "회의를 시작합시다", ref: "회의를 시작합시다") == 0)
    check("cer ja: one substitution → 1/N (会議→会義, N=2)", approx(cerJa(hyp: "会義", ref: "会議"), 0.5))
    // Empty-ref guard: perfect on empty×empty, worst on empty ref vs non-empty hyp.
    check("cer: empty ref + empty hyp → 0", cerJa(hyp: "", ref: "") == 0 && cerKo(hyp: "", ref: "") == 0)
    check("cer: empty ref + non-empty hyp → 1", cerJa(hyp: "x", ref: "") == 1 && cerKo(hyp: "가", ref: "") == 1)
    // Korean syllable-level; denominator = REFERENCE token count. Real partial→final pair (안녕하세 / 안녕하세요).
    check("cer ko: 안녕하세 vs ref 안녕하세요 → 1/5", approx(cerKo(hyp: "안녕하세", ref: "안녕하세요"), 0.2))
    // macOS hands back NFD; NFC makes one Hangul syllable one token (else 강 = three conjoining jamo).
    check("cer ko: NFD input normalizes to one NFC syllable",
          normalizeKo("강".decomposedStringWithCanonicalMapping).count == 1
          && cerKo(hyp: "강".decomposedStringWithCanonicalMapping, ref: "강") == 0)
    // Dakuten MUST survive — が must never fold to か (the NFKD+strip-Mn trap).
    check("cer ja: dakuten preserved (が ≠ か)", normalizeJa("が") == ["が"] && cerJa(hyp: "が", ref: "か") == 1)
    // Non-greedy bracket strip: two parentheticals, only the bracketed spans go (greedy would eat い).
    check("cer ja: non-greedy bracket strip", normalizeJa("あ(拍手)い(笑)う") == ["あ", "い", "う"])
    // Latin lowercased so embedded English isn't case-penalized.
    check("cer: lowercase Latin (GDP == gdp)", cerJa(hyp: "GDP", ref: "gdp") == 0)
    // Korean space-agnostic — 띄어쓰기 differences don't count.
    check("cer ko: whitespace-agnostic (회의 시작 == 회의시작)", cerKo(hyp: "회의 시작", ref: "회의시작") == 0)
    // Bracket strip covers [...] and <...>, not only (...).
    check("cer ja: [...] and <...> brackets stripped", normalizeJa("あ[注]い<x>う") == ["あ", "い", "う"])
    // Punctuation (P*) and symbols (S*) strip — surface marks shouldn't count against the score.
    check("cer: punctuation + symbols stripped", cerJa(hyp: "会議。", ref: "会議") == 0
          && cerKo(hyp: "안녕!", ref: "안녕") == 0 && cerJa(hyp: "A★B", ref: "AB") == 0)
    // stripWhitespace:false is the space-SENSITIVE diagnostic seam — a space now counts as an edit.
    check("cer ko: stripWhitespace:false counts spaces",
          cerKo(hyp: "회의 시작", ref: "회의시작", options: CEROptions(stripWhitespace: false)) > 0)
    // chrF — character n-gram F-score (β=2) for translation quality. Identical → 1, disjoint → 0.
    check("chrf: identical → 1", chrF(candidate: "회의를 시작합시다", reference: "회의를 시작합시다") == 1
          && chrF(candidate: "は", reference: "は") == 1)
    check("chrf: both empty → 1, one empty → 0", chrF(candidate: "", reference: "") == 1
          && chrF(candidate: "x", reference: "") == 0 && chrF(candidate: "", reference: "x") == 0)
    check("chrf: no shared character → 0", chrF(candidate: "猫", reference: "犬") == 0)
    // chrF SCORES punctuation (CER strips it) — 会議。 vs 会議 is a partial match (0.875), never perfect.
    check("chrf: punctuation counts, unlike CER", approx(chrF(candidate: "会議。", reference: "会議"), 0.875)
          && cerJa(hyp: "会議。", ref: "会議") == 0)
    let chrfPartial = chrF(candidate: "会議を始める", reference: "会議を終える")
    check("chrf: partial character overlap scores between 0 and 1", chrfPartial > 0 && chrfPartial < 1)
    // Guard: maxOrder < 1 would trap on `1...maxOrder`; it returns 0 instead of crashing.
    check("chrf: maxOrder < 1 → 0 (no crash)", chrF(candidate: "a", reference: "a", maxOrder: 0) == 0)
    // Eval runner: corpus CER is micro-averaged (Σ edits / Σ N), per engine, sorted best-first.
    let samples = [EvalSample(id: "s1", language: "ja", reference: "会議"),       // 2 chars
                   EvalSample(id: "s2", language: "ko", reference: "회의시작")]    // 4 chars
    let fake: (EvalSample, String) -> String = { s, engine in
        if engine == "A" { return s.reference }                                   // perfect
        return s.id == "s1" ? "会義" : "회의시장"                                  // one substitution each
    }
    let scores = runEval(samples: samples, engines: ["B", "A"], transcribe: fake)
    check("eval runner: corpus CER micro-averaged, engines sorted best-first",
          scores.count == 2 && scores[0].engine == "A" && scores[0].cer == 0 && scores[0].samples == 2
          && scores[1].engine == "B" && approx(scores[1].cer, 2.0 / 6.0))   // 1+1 edits over 2+4 ref chars
    check("eval runner: empty-reference corpus → 0 if silent, 1 if invented",
          runEval(samples: [EvalSample(id: "e", language: "ja", reference: "")], engines: ["x"],
                  transcribe: { _, _ in "" })[0].cer == 0
          && runEval(samples: [EvalSample(id: "e", language: "ja", reference: "")], engines: ["x"],
                     transcribe: { _, _ in "幻" })[0].cer == 1)
    let rpt = evalReport(scores)
    check("eval report: leaderboard lists engines best-CER first with a percentage",
          rpt.contains("0.0%") && rpt.contains("33.3%")
          && rpt.range(of: "A")!.lowerBound < rpt.range(of: "B")!.lowerBound)
    check("eval cerParts: (edits, reference length) per language",
          cerParts(hyp: "会義", ref: "会議", language: "ja") == (1, 2)
          && cerParts(hyp: "회의시장", ref: "회의시작", language: "ko") == (1, 4))
    // A mixed corpus with a hallucinated empty-reference sample pushes corpus CER above 1.
    let mixed = [EvalSample(id: "m1", language: "ja", reference: "会議"),   // 2 chars, engine perfect
                 EvalSample(id: "m2", language: "ja", reference: "")]      // empty ref, engine invents 3 chars
    check("eval runner: hallucinated silence pushes corpus CER above 1",
          approx(runEval(samples: mixed, engines: ["h"],
                         transcribe: { s, _ in s.id == "m1" ? "会議" : "幻幻幻" })[0].cer, 3.0 / 2.0))
    // Equal-CER ties break deterministically by engine name (both perfect → A before B, input order B,A).
    let tie = runEval(samples: samples, engines: ["B", "A"], transcribe: { s, _ in s.reference })
    check("eval runner: equal-CER ties sort by engine name", tie.map { $0.engine } == ["A", "B"])
}
