import Foundation

// MARK: - L3.5 structured daily log (VISION Pillar 1 — a machine-readable record of the day)

// The daily digest is prose an LLM re-absorbs; the STRUCTURED sidecar is the queryable substrate an
// agent acts on. After the digest markdown lands, one more runner call distills it into minified
// JSON next to the digest (`<stem>.json`). Everything here is pure except the runner invocation —
// the prompt, the sidecar path, and (critically) the VALIDATION that refuses to write garbage.

/// The sidecar path for a digest: same stem, `.json`. `<dir>/2026-07-20.md` → `<dir>/2026-07-20.json`.
func structuredSidecarPath(digestPath: String) -> String {
    (digestPath as NSString).deletingPathExtension + ".json"
}

/// The extraction prompt — ONLY minified JSON out, matching the shape validateStructuredDigest checks.
func structuredDigestPrompt(day: String) -> String {
    "From this daily digest, extract a structured record. Output ONLY minified JSON (no markdown, no "
        + "code fence, no prose) with EXACTLY these keys: "
        + "{\"date\":\"\(day)\",\"meetings\":[{\"title\":\"\",\"time\":\"\"}],"
        + "\"decisions\":[{\"text\":\"\",\"meeting\":\"\"}],"
        + "\"actionItems\":[{\"text\":\"\",\"owner\":\"\",\"due\":\"\",\"done\":false}],"
        + "\"entities\":[{\"name\":\"\",\"kind\":\"\"}]}. "
        + "Omit optional string fields when unknown rather than inventing them; keep arrays empty if "
        + "there is nothing. Answer in the digest's own language for text values."
}

/// The runner command: the digest on stdin, JSON to `<outPath>.partial` (Swift validates it and
/// promotes). Same runner CLIs and shell shape as the digest itself.
func structuredDigestInvocation(runner: SummaryRunner, day: String, digestPath: String, outPath: String) -> String {
    let prompt = structuredDigestPrompt(day: day)
    let cat = "cat \(shq(digestPath))"
    let runnerCmd: String
    switch runner {
    case .claude: runnerCmd = "\(cat) | claude --safe-mode -p \(shq(prompt))"
    case .gemini: runnerCmd = "\(cat) | gemini -p \(shq(prompt))"
    case .codex: runnerCmd = "{ printf '%s\\n\\n' \(shq(prompt)); \(cat); } | codex exec -"
    }
    return "\(runnerCmd) > \(shq(outPath)).partial"
}

let structuredCollectionKeys = ["meetings", "decisions", "actionItems", "entities"]

/// Strip ONLY a boundary code fence (a first line of ``` or ```lang, and a trailing ``` line) that
/// models add despite the instruction — never a global replace, which would delete a triple-backtick
/// living INSIDE a JSON string value and silently corrupt it.
func stripBoundaryFence(_ raw: String) -> String {
    var lines = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\n")
    if lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeFirst() }
    if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Parse + shape-check the runner's reply. Returns the CANONICAL minified JSON to write, or nil when
/// the reply isn't a usable structured day — so a hallucinated or truncated answer is never saved.
/// Missing collection keys are DEFAULTED to empty arrays so every sidecar has all four (a consumer
/// can rely on the shape); a present-but-wrong-typed field is rejected.
func validateStructuredDigest(_ raw: String, day: String) -> String? {
    let s = stripBoundaryFence(raw)
    guard let data = s.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          obj["date"] is String else { return nil }
    for key in structuredCollectionKeys where obj[key] != nil {
        if !(obj[key] is [Any]) { return nil }
    }
    // Canonicalize: force the day (the model occasionally echoes a different one), default every
    // collection to [], sort keys + minify so the sidecar is stable and diffable.
    var normalized = obj
    normalized["date"] = day
    for key in structuredCollectionKeys where normalized[key] == nil { normalized[key] = [] }
    guard let out = try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys]) else { return nil }
    return String(decoding: out, as: UTF8.self)
}

/// The promote-or-discard decision for the sidecar, pure so the whole orchestration is testable:
/// the runner's exit status + whatever it wrote → the JSON to promote, or nil to discard (logging
/// the reason). A non-zero exit, an empty reply, or an invalid one all discard.
func structuredSidecarOutcome(exitStatus: Int32, partial: String?, day: String) -> String? {
    guard exitStatus == 0, let partial else { return nil }
    return validateStructuredDigest(partial, day: day)
}
