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
    // CLI plumbing for `macrec eval`: corpus discovery, engine specs, template substitution.
    let refs = ["standup.ko.txt": "회의 시작하겠습니다", "empty.ja.txt": "  "]
    let corpus = evalCorpus(names: ["standup.ko.wav", "empty.ja.wav", "noref.ja.wav",
                                    "cover.mp3", "readme.txt", "bad.en.wav"],
                            read: { refs[$0] })
    check("eval corpus: pairs wav+txt, blank/missing refs stay nil, non-ko/ja skipped",
          corpus.map(\.id) == ["empty", "noref", "standup"]   // cover.mp3/readme.txt/bad.en.wav all skipped
          && corpus.first { $0.id == "standup" }?.reference == "회의 시작하겠습니다"
          && corpus.first { $0.id == "empty" }?.reference == nil
          && corpus.first { $0.id == "noref" }?.reference == nil
          && !corpus.contains { $0.language == "en" })
    // Review round: ids containing ".wav" or dots must keep a lossless id and the RIGHT reference
    // name (a global ".wav"→".txt" replace once silently unscored such clips).
    let dotty = evalCorpus(names: ["a.wav.demo.ko.wav", "b..ja.wav"],
                           read: { ["a.wav.demo.ko.txt": "정답"][$0] })
    check("eval corpus: dotted ids parse losslessly and find their references",
          dotty.map(\.id) == ["a.wav.demo", "b."]
          && dotty.first { $0.id == "a.wav.demo" }?.reference == "정답")
    check("eval engines: spec parsing and safe substitution",
          parseEngineSpec("sv=transcribe-cli -q -m m.gguf {wav}")?.name == "sv"
          && parseEngineSpec("noequals") == nil
          && parseEngineSpec("x=cmd without placeholder") == nil
          && parseEngineSpec("bad/name=cmd {wav}") == nil   // names become out/ file names
          && evalCommand(template: "run -l {lang} {wav}", wav: "/a/b c.ko.wav", lang: "ko")
          == "run -l ko '/a/b c.ko.wav'"
          && evalCommand(template: "run {wav}", wav: "/x/{lang}/c.ko.wav", lang: "ko")
          == "run '/x/{lang}/c.ko.wav'")   // {lang} inside the path survives ({lang} substitutes first)
    check("eval timing: RTF table sorts fastest first",
          evalTimingReport([(engine: "slow", seconds: 20, audioSeconds: 60),
                            (engine: "fast", seconds: 5, audioSeconds: 60)])
              .contains("fast     5.0s     12.0×"))

    // eval-fetch (#31): a YouTube caption track → the spoken transcript, for a ko/ja eval reference.
    // Two real shapes (fixtures modeled on actual tracks): a ROLLING auto-caption (each cue echoes the
    // last finalized line as plain text, then adds newly-spoken words with inline <c>/<timestamp> tags)
    // and a CLEAN track (one plain line per cue). Both must collapse to the same spoken text.
    let rollingKo = """
    WEBVTT
    Kind: captions
    Language: ko

    00:00:02.010 --> 00:00:04.000 align:start position:0%
    [음악]
    안녕하세요<00:00:02.500><c> 여러분</c>

    00:00:04.000 --> 00:00:04.010 align:start position:0%
    안녕하세요 여러분

    00:00:04.010 --> 00:00:06.000 align:start position:0%
    안녕하세요 여러분
    오늘은<00:00:04.500><c> 회의를</c><00:00:05.000><c> 시작합니다</c>
    """
    check("eval-fetch: a rolling auto-caption keeps only the freshly-spoken (tagged) lines, deduped",
          vttToText(rollingKo) == "안녕하세요 여러분 오늘은 회의를 시작합니다")
    let cleanJa = """
    WEBVTT
    Kind: captions
    Language: ja

    00:00:01.000 --> 00:00:03.000
    会議を始めましょう

    00:00:03.000 --> 00:00:05.000
    今日の議題です

    00:00:05.000 --> 00:00:07.000
    今日の議題です
    """
    check("eval-fetch: a clean caption track keeps every line, collapsing consecutive repeats",
          vttToText(cleanJa) == "会議を始めましょう 今日の議題です")
    // NOTE/STYLE blocks (common in human tracks — the kind we PREFER) must not leak their bodies; an
    // SRT-style numeric cue INDEX (before the timing line) is ignored, but a numeric caption TEXT
    // ("10", a year) after it is KEPT — the two were indistinguishable in the first, per-line parser.
    // The NOTE block deliberately embeds a "-->" (a timing note): without the block-skip, the cue
    // parser's timing-line guard would treat that arrow as the cue timing and leak "번역: 자원봉사자".
    let noisy = """
    WEBVTT

    NOTE
    구간 00:01 --> 00:03 검수함
    번역: 자원봉사자

    STYLE
    ::cue { color: white }

    1
    00:00:01.000 --> 00:00:03.000
    2024년 회의

    2
    00:00:03.000 --> 00:00:05.000
    10
    """
    check("eval-fetch: NOTE/STYLE bodies don't leak (even a NOTE with -->); numeric cue-index skipped but numeric TEXT kept",
          vttToText(noisy) == "2024년 회의 10")
    // Tag-strip is scoped to WebVTT tag shapes: a genuine "<"/">" in speech survives, real tags go.
    check("eval-fetch: tag strip keeps a literal < > in speech, removes c/v/timestamp tags",
          stripVttTags("5 < 10 > 3 이면 통과") == "5 < 10 > 3 이면 통과"
              && stripVttTags("안녕<c.colorE5E5E5> 여러분</c>") == "안녕 여러분"
              && stripVttTags("<v 화자>회의</v>あ<00:00:01.500>い") == "회의あい")
    check("eval-fetch: an empty/header-only VTT parses to empty (no crash)",
          vttToText("WEBVTT\n\n").isEmpty && vttToText("").isEmpty)
    check("eval-fetch: language aliases resolve, others reject",
          evalFetchLang("ko") == "ko" && evalFetchLang("Korean") == "ko"
              && evalFetchLang("jp") == "ja" && evalFetchLang("japanese") == "ja"
              && evalFetchLang("en") == nil && evalFetchLang("") == nil)
    // A user --id can't escape the corpus dir (path traversal): no separators or parent refs survive.
    check("eval-fetch: stem sanitization strips path separators and parent refs",
          !evalFetchStem("../../etc/passwd").contains("/") && !evalFetchStem("../../etc/passwd").contains("..")
              && evalFetchStem("2026-07-standup") == "2026-07-standup" && evalFetchStem("  ") == "clip")
}
