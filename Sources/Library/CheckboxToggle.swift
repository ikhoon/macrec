import Foundation

// MARK: - clickable task checkboxes (pure decisions)

/// The source line index carried by a rendered checkbox ("macrec-check://<line>"), else nil.
func macrecCheckLine(_ link: Any) -> Int? {
    let s = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
    guard s.hasPrefix("macrec-check://") else { return nil }
    return Int(s.dropFirst("macrec-check://".count))
}

/// `text` with the checkbox on source line `line` flipped ([ ] ↔ [x]) — nil when that line is not
/// a task item (the file changed since the render; refuse rather than corrupt a random line).
func toggledCheckboxText(_ text: String, line: Int) -> String? {
    var lines = text.components(separatedBy: "\n")
    guard line >= 0, line < lines.count else { return nil }
    let l = lines[line]
    if let r = l.range(of: "[ ] ") {
        lines[line] = l.replacingCharacters(in: r, with: "[x] ")
    } else if let r = l.range(of: "[x] ") ?? l.range(of: "[X] ") {
        lines[line] = l.replacingCharacters(in: r, with: "[ ] ")
    } else {
        return nil
    }
    return lines.joined(separator: "\n")
}
