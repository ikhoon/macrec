import Foundation

// MARK: - clickable task checkboxes (pure decisions)

/// The source line index carried by a rendered checkbox ("macrec-check://<line>"), else nil.
func macrecCheckLine(_ link: Any) -> Int? {
    let s = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
    guard s.hasPrefix("macrec-check://") else { return nil }
    return Int(s.dropFirst("macrec-check://".count))
}

/// The ONE task-item parser both the renderer and the toggler use — enablement and action must
/// derive from the same source, or a drifted line gets a stale click into the wrong bracket.
/// Accepts "- [ ] task", "* [x]", "1. [ ]", an empty "- [ ]", at any indent; returns the bracket's
/// range and checked state, else nil.
func taskCheckbox(in line: String) -> (range: Range<String.Index>, checked: Bool)? {
    var idx = line.startIndex
    while idx < line.endIndex, line[idx] == " " { idx = line.index(after: idx) }
    // List marker: -, *, + or digits followed by . or )
    if idx < line.endIndex, "-*+".contains(line[idx]) {
        idx = line.index(after: idx)
    } else {
        var d = idx
        while d < line.endIndex, line[d].isNumber { d = line.index(after: d) }
        guard d > idx, d < line.endIndex, ".)".contains(line[d]) else { return nil }
        idx = line.index(after: d)
    }
    guard idx < line.endIndex, line[idx] == " " else { return nil }
    idx = line.index(after: idx)
    let rest = line[idx...]
    for (token, checked) in [("[ ]", false), ("[x]", true), ("[X]", true)] {
        if rest.hasPrefix(token + " ") || rest == Substring(token) {
            return (idx ..< line.index(idx, offsetBy: token.count), checked)
        }
    }
    return nil
}

/// `text` with the checkbox on source line `line` flipped — nil when that line no longer parses as
/// a task item (a drifted file must be refused, never corrupted).
func toggledCheckboxText(_ text: String, line: Int) -> String? {
    var lines = text.components(separatedBy: "\n")
    guard line >= 0, line < lines.count, let box = taskCheckbox(in: lines[line]) else { return nil }
    lines[line] = lines[line].replacingCharacters(in: box.range, with: box.checked ? "[ ]" : "[x]")
    return lines.joined(separator: "\n")
}
