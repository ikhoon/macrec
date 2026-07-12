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
