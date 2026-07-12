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
}
