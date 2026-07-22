import AppKit

// MARK: - markdown rendering for the Library preview

/// Renders the markdown subset macrec's own transcripts, summaries and digests emit — headings,
/// bullet/numbered lists (with wrapped continuation lines), blockquotes, code spans and fences,
/// bold/italic, links and bare URLs. A PURE function of (text, baseURL) → NSAttributedString so the
/// mapping is selftestable; anything outside the subset degrades to styled plain text, never an
/// error (a transcript's calendar-notes section carries arbitrary pasted text).
enum MarkdownRender {
    /// A preview, not an editor: past this many characters render as plain text (attributed-string
    /// styling of megabyte files beachballs the window; real documents are tens of KB).
    static let renderCap = 400_000

    // Fonts/colors are computed per call — they resolve against the CURRENT appearance.
    private static var body: NSFont { .systemFont(ofSize: 13) }
    private static var mono: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
    private static func heading(_ level: Int) -> NSFont {
        switch level {
        case 1: return .systemFont(ofSize: 19, weight: .bold)
        case 2: return .systemFont(ofSize: 16, weight: .bold)
        case 3: return .systemFont(ofSize: 14, weight: .semibold)
        default: return .systemFont(ofSize: 13, weight: .semibold)
        }
    }

    /// `transcriptStart` (seconds since midnight, from the file stem's minute) turns each line's
    /// leading "[HH:MM:SS]" stamp into a macrec-seek: link — pass it only for a transcript that
    /// HAS audio; nil renders stamps as plain text.
    static func render(_ text: String, baseURL: URL? = nil, transcriptStart: Int? = nil) -> NSAttributedString {
        guard !text.isEmpty else { return NSAttributedString() }
        guard text.count <= renderCap else {
            return NSAttributedString(string: text, attributes: [.font: mono, .foregroundColor: NSColor.labelColor])
        }
        // Normalize CRLF/CR first: `.whitespaces` trimming does NOT strip \r, so an un-normalized
        // Windows-authored file keeps a carriage return on every line and rule/quote detection
        // breaks. The probe must be UTF-16-level: "\r\n" is ONE Swift grapheme, so the obvious
        // text.contains("\r") answers false for pure-CRLF input and skips the normalization.
        let normalized = text.utf16.contains(13)
            ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            : text
        let out = NSMutableAttributedString()
        var inFence = false
        let lines = normalized.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {   // fence markers toggle the block and are not shown
                inFence.toggle()
                continue
            }
            if inFence {
                out.append(NSAttributedString(string: line + "\n", attributes: [
                    .font: mono,
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.labelColor.withAlphaComponent(0.06),
                    .paragraphStyle: style(firstIndent: 10, headIndent: 10),
                ]))
                continue
            }
            if trimmed.isEmpty {
                out.append(NSAttributedString(string: "\n"))
                continue
            }
            // Horizontal rule — a light drawn line, not the raw dashes.
            if trimmed.count >= 3, Set(trimmed) == ["-"] || Set(trimmed) == ["*"] || Set(trimmed) == ["_"] {
                out.append(NSAttributedString(string: "──────────\n", attributes: [
                    .font: body, .foregroundColor: NSColor.separatorColor,
                ]))
                continue
            }
            // Transcript stamp: with the recording's start clock in hand, "[HH:MM:SS]" becomes a
            // macrec-seek: link the Library player intercepts — click a line, hear that moment.
            // Checked BEFORE the table branch: a stamped line containing a "|" must stay a seek
            // line even when the next line happens to look like a table separator.
            if let startSec = transcriptStart, let stamp = transcriptLineStamp(trimmed) {
                let para = style(firstIndent: 0, headIndent: 0)
                para.paragraphSpacing = 2
                let stampText = String(trimmed.prefix(stamp.length))
                let offset = transcriptSeekOffset(lineSeconds: stamp.clockSeconds, startSeconds: startSec)
                let lineOut = NSMutableAttributedString()
                if let link = macrecSeekLink(offsetSeconds: offset) {
                    lineOut.append(NSAttributedString(string: stampText, attributes: [
                        .font: mono, .foregroundColor: NSColor.labelColor, .link: link,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .toolTip: "Play from here",
                    ]))
                } else {
                    lineOut.append(NSAttributedString(string: stampText, attributes: [
                        .font: mono, .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
                }
                lineOut.append(inline(String(trimmed.dropFirst(stamp.length)),
                                      font: body, color: .labelColor, baseURL: baseURL))
                out.append(applying(para, to: lineOut))
                out.append(NSAttributedString(string: "\n"))
                continue
            }
            // Pipe table: a |-row whose NEXT line is the |---|---| separator starts one; body rows
            // follow until the first non-|-row. Anything malformed falls through to plain text.
            if isTableRow(trimmed), i < lines.count,
               isTableSeparator(lines[i].trimmingCharacters(in: .whitespaces)),
               parseTableRow(lines[i].trimmingCharacters(in: .whitespaces)).count == parseTableRow(trimmed).count {
                var rows = [parseTableRow(trimmed)]
                var j = i + 1   // skip the separator line
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    guard isTableRow(t) else { break }
                    rows.append(parseTableRow(t))
                    j += 1
                }
                out.append(renderTable(rows, baseURL: baseURL))
                i = j
                continue
            }
            // Heading: 1–6 hashes, a space, then text.
            if let h = headingLevel(trimmed) {
                let para = style(firstIndent: 0, headIndent: 0)
                para.paragraphSpacingBefore = 8
                para.paragraphSpacing = 3
                let content = inline(String(trimmed.dropFirst(h + 1)),
                                     font: heading(h), color: .labelColor, baseURL: baseURL)
                out.append(applying(para, to: content))
                out.append(NSAttributedString(string: "\n"))
                continue
            }
            // Blockquote.
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                let content = inline(String(trimmed.dropFirst(trimmed == ">" ? 1 : 2)),
                                     font: body, color: .secondaryLabelColor, baseURL: baseURL)
                let quoted = NSMutableAttributedString(string: "▎ ", attributes: [
                    .font: body, .foregroundColor: NSColor.tertiaryLabelColor,
                ])
                quoted.append(content)
                out.append(applying(style(firstIndent: 4, headIndent: 16), to: quoted))
                out.append(NSAttributedString(string: "\n"))
                continue
            }
            // List item: "-", "*", "+" or "1." / "1)" after optional indent. Requires a following
            // space, so a transcript's "-::~:~…" separator art stays plain text.
            if let item = listItem(line) {
                let indent = CGFloat(item.level) * 16
                let para = style(firstIndent: indent, headIndent: indent + 18)
                para.paragraphSpacing = 2
                // Task-list items: "- [ ] track me" / "- [x] done" become checkbox rows — the
                // summarizer emits action items in this shape so they stay trackable in the vault.
                var markerGlyph = item.marker
                var bodyText = item.text
                var bodyColor = NSColor.labelColor
                if bodyText.hasPrefix("[ ] ") {
                    markerGlyph = "☐"; bodyText = String(bodyText.dropFirst(4))
                } else if bodyText.lowercased().hasPrefix("[x] ") {
                    markerGlyph = "☑"; bodyText = String(bodyText.dropFirst(4))
                    bodyColor = .secondaryLabelColor   // done items read as done
                }
                let marker = NSMutableAttributedString(string: markerGlyph + "  ", attributes: [
                    .font: body, .foregroundColor: NSColor.secondaryLabelColor,
                ])
                marker.append(inline(bodyText, font: body, color: bodyColor, baseURL: baseURL))
                out.append(applying(para, to: marker))
                out.append(NSAttributedString(string: "\n"))
                continue
            }
            // A continuation line of a wrapped list item (indented plain text) keeps the hang;
            // everything else is a plain paragraph.
            let leading = line.prefix(while: { $0 == " " }).count
            let para = leading >= 2
                ? style(firstIndent: 18, headIndent: 18)
                : style(firstIndent: 0, headIndent: 0)
            para.paragraphSpacing = 2
            out.append(applying(para, to: inline(trimmed, font: body, color: .labelColor, baseURL: baseURL)))
            out.append(NSAttributedString(string: "\n"))
        }
        return out
    }

    // MARK: tables

    /// Any line with a pipe can be a row — it only BECOMES a table when the next line is a
    /// separator with a matching cell count (checked at the call site), so prose with a stray
    /// "|" never turns into a grid.
    static func isTableRow(_ s: String) -> Bool { s.contains("|") }

    /// The |---|:---:|---| row. Every cell is dashes with optional alignment colons.
    static func isTableSeparator(_ s: String) -> Bool {
        let cells = parseTableRow(s)
        return !cells.isEmpty && cells.allSatisfy { c in
            c.contains("-") && c.allSatisfy { "-:".contains($0) }
        }
    }

    /// "| a | b |" → ["a", "b"] (outer pipes optional, cells trimmed).
    static func parseTableRow(_ s: String) -> [String] {
        var t = s
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Rows → a real NSTextTable (bordered cells, shaded semibold header). Ragged body rows pad
    /// or truncate to the header's column count.
    private static func renderTable(_ rows: [[String]], baseURL: URL?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let table = NSTextTable()
        let cols = max(rows[0].count, 1)
        table.numberOfColumns = cols
        let cellFont = NSFont.systemFont(ofSize: 12.5)
        let headFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        for (r, row) in rows.enumerated() {
            for c in 0..<cols {
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1,
                                             startingColumn: c, columnSpan: 1)
                block.setBorderColor(NSColor.separatorColor)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setWidth(5, type: .absoluteValueType, for: .padding)
                if r == 0 { block.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05) }
                let para = NSMutableParagraphStyle()
                para.textBlocks = [block]
                let content = NSMutableAttributedString(attributedString: inline(
                    c < row.count ? row[c] : "", font: r == 0 ? headFont : cellFont,
                    color: .labelColor, baseURL: baseURL))
                content.append(NSAttributedString(string: "\n", attributes: [.font: cellFont]))
                content.addAttribute(.paragraphStyle, value: para,
                                     range: NSRange(location: 0, length: content.length))
                out.append(content)
            }
        }
        return out
    }

    // MARK: block helpers

    private static func headingLevel(_ s: String) -> Int? {
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard hashes >= 1, hashes <= 6, s.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> (level: Int, marker: String, text: String)? {
        let spaces = line.prefix(while: { $0 == " " }).count
        let rest = String(line.dropFirst(spaces))
        if rest.count >= 2, "-*+".contains(rest.first!), rest.dropFirst().first == " " {
            return (spaces / 2, "•", String(rest.dropFirst(2)))
        }
        let digits = rest.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if after.first == "." || after.first == ")", after.dropFirst().first == " " {
                return (spaces / 2, digits + ".", String(after.dropFirst(2)))
            }
        }
        return nil
    }

    private static func style(firstIndent: CGFloat, headIndent: CGFloat) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = firstIndent
        p.headIndent = headIndent
        p.lineSpacing = 2
        return p
    }

    private static func applying(_ para: NSParagraphStyle, to s: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
        return m
    }

    // MARK: inline styling

    // One alternation, first-match-wins left to right: code span, [text](url), **bold**, *italic*,
    // bare URL. The bare-URL class is ASCII-URL-only so trailing prose (Korean particles glued to a
    // URL, closing brackets) never rides along. Link URLs allow ONE level of balanced parentheses
    // (Wikipedia-style "..._(disambiguation)") — CommonMark's full nesting isn't worth the regex.
    private static let urlClass = "(?:[^()\\s]|\\([^()\\s]*\\))+"
    /// The patterns are static and covered by selftests — an invalid one is a programmer error,
    /// caught at first render in any test run (this beats `try!`, which the linter rightly bans).
    private static func rx(_ pattern: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern) }
        catch { preconditionFailure("MarkdownRender: invalid pattern \(pattern) — \(error)") }
    }

    private static let inlineRx = rx(
        "(`[^`\\n]+`)"
            + "|(\\[[^\\]\\n]+\\]\\(" + urlClass + "\\))"
            + "|(\\*\\*[^*\\n]+\\*\\*)"
            + "|(?<![\\w*])\\*([^*\\n]+)\\*(?![\\w*])"
            + "|(https?://[A-Za-z0-9\\-._~:/?#@!$&'+,;=%]+)")
    private static let linkRx = rx("\\[([^\\]\\n]+)\\]\\((" + urlClass + ")\\)")
    /// A single line longer than this skips inline styling: the link alternation backtracks
    /// quadratically on pathological bracket floods (measured: 33 s at 40k chars), and no real
    /// document has a 4k-char LINE that needs styling.
    static let inlineLineCap = 4000

    static func inline(_ s: String, font: NSFont, color: NSColor, baseURL: URL?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let ns = s as NSString
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        guard ns.length <= inlineLineCap else { return NSAttributedString(string: s, attributes: plain) }
        var pos = 0
        inlineRx.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m else { return }
            if m.range.location > pos {
                out.append(NSAttributedString(string: ns.substring(with: NSRange(location: pos, length: m.range.location - pos)), attributes: plain))
            }
            let token = ns.substring(with: m.range)
            if token.hasPrefix("`") {
                out.append(NSAttributedString(string: String(token.dropFirst().dropLast()), attributes: [
                    .font: mono, .foregroundColor: color,
                    .backgroundColor: NSColor.labelColor.withAlphaComponent(0.08),
                ]))
            } else if token.hasPrefix("[") {
                if let lm = linkRx.firstMatch(in: token, range: NSRange(location: 0, length: (token as NSString).length)) {
                    let t = (token as NSString).substring(with: lm.range(at: 1))
                    let u = (token as NSString).substring(with: lm.range(at: 2))
                    if let url = resolveLink(u, baseURL: baseURL) {
                        out.append(NSAttributedString(string: t, attributes: [
                            .font: font, .foregroundColor: NSColor.labelColor, .link: url,
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                        ]))
                    } else {
                        out.append(NSAttributedString(string: t, attributes: plain))
                    }
                } else {
                    out.append(NSAttributedString(string: token, attributes: plain))
                }
            } else if token.hasPrefix("**") {
                out.append(NSAttributedString(string: String(token.dropFirst(2).dropLast(2)), attributes: [
                    .font: NSFont.systemFont(ofSize: font.pointSize, weight: .bold), .foregroundColor: color,
                ]))
            } else if token.hasPrefix("*") {
                // Synthetic slant instead of an italic face: the CJK fallback fonts have no italic
                // face at all, so trait conversion leaves Korean/Japanese emphasis invisible.
                out.append(NSAttributedString(string: String(token.dropFirst().dropLast()), attributes: [
                    .font: font, .foregroundColor: color, .obliqueness: 0.15,
                ]))
            } else {   // bare URL — trim sentence punctuation that glued on
                var urlText = token
                while let last = urlText.last, ".,;:!?".contains(last) { urlText.removeLast() }
                let trailing = String(token.dropFirst(urlText.count))
                if let url = URL(string: urlText) {
                    out.append(NSAttributedString(string: urlText, attributes: [
                        .font: font, .foregroundColor: NSColor.labelColor, .link: url,
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ]))
                } else {
                    out.append(NSAttributedString(string: urlText, attributes: plain))
                }
                if !trailing.isEmpty { out.append(NSAttributedString(string: trailing, attributes: plain)) }
            }
            pos = m.range.location + m.range.length
        }
        if pos < ns.length {
            out.append(NSAttributedString(string: ns.substring(from: pos), attributes: plain))
        }
        return out
    }

    /// A markdown link becomes clickable only when it resolves to something safe to hand to
    /// NSWorkspace: web/mail schemes, or a path relative to the document (the transcript's audio
    /// link). Anything else — unknown schemes, unparseable URLs — renders as plain text.
    static func resolveLink(_ raw: String, baseURL: URL?) -> URL? {
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased() {
            return ["http", "https", "mailto", "obsidian", "file"].contains(scheme) ? url : nil
        }
        guard let base = baseURL else { return nil }
        return URL(string: raw, relativeTo: base)?.absoluteURL.standardized   // resolve the ../ hops
    }
}
