import Foundation

// ko/ja transcription-quality metrics — pure, no IO. Character Error Rate (CER) is the CJK standard
// (word boundaries are unreliable, so WER misleads). Every rule here has a selftest reproducing the
// exact ko/ja value it guards. Translation scoring (chrF) and the runner land in later PRs.

/// CER options. `jamo`-level and space-sensitive scoring are a future diagnostic seam; today only the
/// default path (syllable-level for ko, whitespace-stripped) is implemented.
struct CEROptions: Equatable {
    var stripWhitespace = true
}

/// Levenshtein edit distance over grapheme-cluster tokens (unit sub/ins/del cost, two-row DP).
func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var prev = Array(0...b.count)
    var curr = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        curr[0] = i
        for j in 1...b.count {
            let sub = prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
            curr[j] = min(prev[j] + 1, curr[j - 1] + 1, sub)
        }
        swap(&prev, &curr)
    }
    return prev[b.count]
}

/// Punctuation (P*) and Symbol (S*) always strip; Mark (M*) strips only for ja (`marks: true`), where
/// NFKC has already composed precomposable voiced kana into a Letter so the dakuten survives — a lone
/// combining mark on a non-composable base is dropped (documented limitation).
private func isStrippable(_ scalar: Unicode.Scalar, marks: Bool) -> Bool {
    switch scalar.properties.generalCategory {
    case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
         .initialPunctuation, .finalPunctuation, .otherPunctuation,
         .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
        return true
    case .nonspacingMark, .spacingMark, .enclosingMark:
        return marks
    default:
        return false
    }
}

/// Remove bracketed annotations — (...), [...], <...> — NON-greedily, so separate pairs don't merge
/// (a greedy `\(.*\)` would eat everything between the first "(" and the last ")").
private func stripBrackets(_ s: String) -> String {
    var out = s
    for pattern in [#"\([^)]*\)"#, #"\[[^\]]*\]"#, #"<[^>]*>"#] {
        out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    return out
}

private func normalizedTokens(_ s: String, canonical: Bool, marks: Bool, stripWhitespace: Bool) -> [Character] {
    // ko: NFC (macOS hands back NFD, so one Hangul syllable arrives as conjoining jamo → NFC = 1 Char).
    // ja: NFKC (folds full/half-width, composes dakuten into a Letter before symbol removal).
    var t = canonical ? s.precomposedStringWithCanonicalMapping : s.precomposedStringWithCompatibilityMapping
    t = stripBrackets(t)
    t = t.lowercased()   // Latin only; Hangul/kana/kanji unaffected — embedded English isn't case-penalized
    var out = String.UnicodeScalarView()
    for scalar in t.unicodeScalars {
        if isStrippable(scalar, marks: marks) { continue }
        if stripWhitespace && scalar.properties.isWhitespace { continue }
        out.append(scalar)
    }
    return Array(String(out))
}

/// Japanese normalization → grapheme-cluster tokens. NFKC; strips punctuation/symbol/mark + whitespace.
/// NEVER NFKD+strip-Mn: that turns が→か and destroys voicing (the single most damaging ja misconfig).
func normalizeJa(_ s: String) -> [Character] {
    normalizedTokens(s, canonical: false, marks: true, stripWhitespace: true)
}

/// Korean normalization → syllable (완성형) tokens. NFC; strips punctuation/symbol + whitespace
/// (space-agnostic default, robust to 띄어쓰기 guesswork).
func normalizeKo(_ s: String, _ opts: CEROptions = CEROptions()) -> [Character] {
    normalizedTokens(s, canonical: true, marks: false, stripWhitespace: opts.stripWhitespace)
}

/// CER = editDistance(hyp, ref) / |ref|. Denominator is the REFERENCE token count. Empty-ref guard:
/// empty ref + empty hyp → 0 (perfect); empty ref + non-empty hyp → 1 (all insertions).
private func cer(_ hyp: [Character], _ ref: [Character]) -> Double {
    if ref.isEmpty { return hyp.isEmpty ? 0.0 : 1.0 }
    return Double(levenshtein(hyp, ref)) / Double(ref.count)
}

func cerJa(hyp: String, ref: String) -> Double { cer(normalizeJa(hyp), normalizeJa(ref)) }
func cerKo(hyp: String, ref: String, options: CEROptions = CEROptions()) -> Double {
    cer(normalizeKo(hyp, options), normalizeKo(ref, options))
}

/// chrF — a character n-gram F-score (orders 1…`maxOrder`, β=`beta`), a reference-based TRANSLATION
/// metric that sidesteps CJK word segmentation by scoring on characters. Range 0…1 (1 = identical).
/// Unlike CER, punctuation is KEPT (it carries meaning in a translation, and chrF is defined to score
/// it); text is NFC-normalized and whitespace-stripped, case preserved. Averaging convention: precision
/// and recall are averaged over the EFFECTIVE orders (those short enough that both strings have n-grams)
/// FIRST, then one F-beta — so a short utterance isn't penalized for orders longer than itself.
/// Both-empty → 1; one-empty → 0. Pure + selftested. (Exact sacreBLEU eps-parity is a future refinement.)
func chrF(candidate: String, reference: String, maxOrder: Int = 6, beta: Double = 2) -> Double {
    let cand = chrfChars(candidate), ref = chrfChars(reference)
    if cand.isEmpty, ref.isEmpty { return 1 }
    var precs: [Double] = [], recs: [Double] = []
    for n in 1...maxOrder {
        let cg = charNgrams(cand, n), rg = charNgrams(ref, n)
        let nCand = cg.values.reduce(0, +), nRef = rg.values.reduce(0, +)
        guard nCand > 0, nRef > 0 else { continue }   // an order longer than a string isn't effective
        var match = 0
        for (gram, c) in cg { match += min(c, rg[gram] ?? 0) }
        precs.append(Double(match) / Double(nCand))
        recs.append(Double(match) / Double(nRef))
    }
    guard !precs.isEmpty else { return 0 }            // no shared order length → no character overlap
    let avgP = precs.reduce(0, +) / Double(precs.count)
    let avgR = recs.reduce(0, +) / Double(recs.count)
    guard avgP + avgR > 0 else { return 0 }
    let b2 = beta * beta
    return (1 + b2) * avgP * avgR / (b2 * avgP + avgR)
}

/// NFC + whitespace-strip; punctuation and case PRESERVED (chrF scores them). Characters are Unicode
/// scalars (code points), matching sacreBLEU chrF — not grapheme clusters.
private func chrfChars(_ s: String) -> [Character] {
    Array(s.precomposedStringWithCanonicalMapping.unicodeScalars
        .filter { !$0.properties.isWhitespace }.map(Character.init))
}

private func charNgrams(_ chars: [Character], _ n: Int) -> [String: Int] {
    guard chars.count >= n else { return [:] }
    var counts: [String: Int] = [:]
    for i in 0...(chars.count - n) { counts[String(chars[i..<(i + n)]), default: 0] += 1 }
    return counts
}
