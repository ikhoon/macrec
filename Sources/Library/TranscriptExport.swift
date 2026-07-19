import Foundation

// MARK: - transcript timestamp lines (playback sync + subtitle export share this parsing)

/// Parse a leading "[HH:MM:SS]" wall-clock stamp — the shape every saved transcript line starts
/// with ("[14:01:12] Me: …"). Returns the clock as seconds since midnight plus the token's length.
/// Strict 2-2-2 digits with a closing bracket, so whisper's raw "[HH:MM:SS.mmm --> …]" ranges and
/// prose that merely opens a bracket never parse. Pure + selftested.
func transcriptLineStamp(_ line: String) -> (clockSeconds: Int, length: Int)? {
    let chars = Array(line.prefix(10))
    guard chars.count == 10, chars[0] == "[", chars[9] == "]", chars[3] == ":", chars[6] == ":",
          [1, 2, 4, 5, 7, 8].allSatisfy({ chars[$0].isNumber }),
          let h = Int(String(chars[1...2])), let m = Int(String(chars[4...5])),
          let s = Int(String(chars[7...8])), h < 24, m < 60, s < 60 else { return nil }
    return (h * 3600 + m * 60 + s, 10)
}

/// The library entry's "HH:MM" start (from the file stem's minute) → seconds since midnight.
func libraryStartSeconds(_ hhmm: String?) -> Int? {
    guard let t = hhmm, t.count == 5, Array(t)[2] == ":",
          let h = Int(t.prefix(2)), let m = Int(t.suffix(2)),
          h < 24, m < 60 else { return nil }
    return h * 3600 + m * 60
}

/// Wall-clock line time → seconds into the recording. Both clocks are time-of-day, so a recording
/// that crosses midnight reads hugely negative (23:50 start, 00:05 line → -85 500 s) and +24 h
/// restores the real 900 s. No segment runs 12 h, so an offset that lands ≥ 12 h after the wrap is
/// really a clock slightly BEFORE the stem's minute (whisper stamps can precede the minute-precision
/// stem) — clamped to 0 rather than seeking a day ahead. Pure + selftested with those numbers.
func transcriptSeekOffset(lineSeconds: Int, startSeconds: Int) -> Double {
    var off = lineSeconds - startSeconds
    if off < 0 { off += 24 * 3600 }
    return off >= 12 * 3600 ? 0 : Double(off)
}

// MARK: - seek links (the renderer mints them, the Library player consumes them)

/// Custom scheme carrying "seconds into the recording" from a rendered stamp to the player.
/// Deliberately NOT in MarkdownRender.resolveLink's allowlist: only the transcript renderer mints
/// these, so a document's own `[text](macrec-seek:…)` link stays plain text.
let macrecSeekScheme = "macrec-seek"

func macrecSeekLink(offsetSeconds: Double) -> URL? {
    URL(string: "\(macrecSeekScheme):\(Int(offsetSeconds.rounded()))")
}

/// A clicked link back into the offset (NSTextView hands the delegate URL or String).
/// nil for foreign links → the caller falls through to the default open-in-browser handling.
func macrecSeekSeconds(_ link: Any) -> Double? {
    let raw = (link as? URL)?.absoluteString ?? (link as? String ?? "")
    guard raw.hasPrefix(macrecSeekScheme + ":"),
          let v = Double(raw.dropFirst(macrecSeekScheme.count + 1)),
          v.isFinite, v >= 0 else { return nil }
    return v
}

// MARK: - export conversions (pure: markdown in, the chosen format out)

/// The formats the Export… panel offers. Markdown is the file as saved; the rest are conversions.
enum TranscriptExportFormat: CaseIterable {
    case markdown, plainText, srt, vtt
    var label: String {
        switch self {
        case .markdown: return "Markdown (.md)"
        case .plainText: return "Plain text (.txt)"
        case .srt: return "SubRip subtitles (.srt)"
        case .vtt: return "WebVTT subtitles (.vtt)"
        }
    }

    var ext: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        case .srt: return "srt"
        case .vtt: return "vtt"
        }
    }
}

/// One subtitle cue: seconds into the recording; the text keeps the speaker prefix ("Me: …").
struct TranscriptCue: Equatable {
    var start: Double
    var end: Double
    var text: String
}

/// "[HH:MM:SS] Speaker: text" lines → cues. Each cue ends where the next begins (min 1 s — two
/// lines can share a second); the last runs +5 s. Non-stamped lines (title, metadata, headings)
/// are not speech and carry no cue. `startSeconds` nil (a stem with no time) anchors the first
/// stamped line at 0. Pure + selftested.
func transcriptCues(_ markdown: String, startSeconds: Int?) -> [TranscriptCue] {
    var stamped: [(offset: Double, text: String)] = []
    var anchor = startSeconds
    for raw in markdown.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard let stamp = transcriptLineStamp(line) else { continue }
        let text = String(line.dropFirst(stamp.length)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { continue }
        if anchor == nil { anchor = stamp.clockSeconds }
        stamped.append((transcriptSeekOffset(lineSeconds: stamp.clockSeconds, startSeconds: anchor!), text))
    }
    return stamped.enumerated().map { i, s in
        let end = i + 1 < stamped.count ? max(stamped[i + 1].offset, s.offset + 1) : s.offset + 5
        return TranscriptCue(start: s.offset, end: end, text: s.text)
    }
}

/// "HH:MM:SS<sep>mmm" — SRT separates milliseconds with a comma, VTT with a dot.
func subtitleClock(_ seconds: Double, millisSeparator: String) -> String {
    let total = Int((max(seconds, 0) * 1000).rounded())
    return String(format: "%02d:%02d:%02d", total / 3_600_000, total / 60000 % 60, total / 1000 % 60)
        + millisSeparator + String(format: "%03d", total % 1000)
}

func transcriptToSRT(_ markdown: String, start: Int?) -> String {
    transcriptCues(markdown, startSeconds: start).enumerated().map { i, c in
        "\(i + 1)\n\(subtitleClock(c.start, millisSeparator: ",")) --> "
            + "\(subtitleClock(c.end, millisSeparator: ","))\n\(c.text)\n"
    }.joined(separator: "\n")
}

func transcriptToVTT(_ markdown: String, start: Int?) -> String {
    "WEBVTT\n\n" + transcriptCues(markdown, startSeconds: start).map { c in
        "\(subtitleClock(c.start, millisSeparator: ".")) --> "
            + "\(subtitleClock(c.end, millisSeparator: "."))\n\(c.text)\n"
    }.joined(separator: "\n")
}

/// Markdown → readable plain text: heading hashes, blockquote bars, emphasis/code markers, link
/// syntax and fence/table-separator lines go; the text, list markers and stamped lines stay.
func transcriptToPlainText(_ markdown: String) -> String {
    var out: [String] = []
    for raw in markdown.components(separatedBy: "\n") {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { continue }   // fence markers go, the fenced content stays
        if trimmed.contains("|"), MarkdownRender.isTableSeparator(trimmed) { continue }
        var line = raw
        for (pattern, tmpl) in [
            ("^(\\s*)#{1,6} ", "$1"),                                     // heading hashes
            ("^(\\s*)> ?", "$1"),                                         // blockquote bar
            ("`([^`\\n]+)`", "$1"),                                       // code span
            ("\\[([^\\]\\n]+)\\]\\((?:[^()\\s]|\\([^()\\s]*\\))+\\)", "$1"), // [text](url) → text
            ("\\*\\*([^*\\n]+)\\*\\*", "$1"),                             // bold
            ("(?<![\\w*])\\*([^*\\n]+)\\*(?![\\w*])", "$1"),              // italic
        ] {
            line = line.replacingOccurrences(of: pattern, with: tmpl, options: .regularExpression)
        }
        out.append(line)
    }
    return out.joined(separator: "\n")
}

/// The exported bytes for one format — the single dispatch the save panel calls. Pure + selftested.
func transcriptExportContent(_ markdown: String, format: TranscriptExportFormat, startSeconds: Int?) -> String {
    switch format {
    case .markdown: return markdown
    case .plainText: return transcriptToPlainText(markdown)
    case .srt: return transcriptToSRT(markdown, start: startSeconds)
    case .vtt: return transcriptToVTT(markdown, start: startSeconds)
    }
}

// MARK: - preview-header action decisions (enablement and the action are ONE decision)

/// Export… converts the transcript document — only transcript rows have one.
func libraryExportEnabled(_ kind: LibraryEntry.Kind?) -> Bool { kind == .transcript }

/// Where a re-run of the summary stands for one transcript.
enum LibraryRerunPhase: Equatable { case idle, running, failed(String) }

/// What the re-run slot in the preview header shows: a button (nil = hidden), a spinner, a status
/// line. Derived in one place so a visible button always has a workable action behind it.
struct LibrarySummarySlot: Equatable {
    var buttonTitle: String? // nil = no button
    var spinning: Bool
    var status: String? // nil = no label
}

/// The slot exists only when clicking could actually produce a summary: a transcript row, the
/// built-in summary mode (a freeform shell hook writes nowhere we could refresh or reap), and a
/// buildable invocation. Everything else hides the whole slot — never a dead button. Pure + selftested.
func librarySummarySlot(kind: LibraryEntry.Kind?, hasInvocation: Bool, writesSummaryFile: Bool,
                        hasSummary: Bool, phase: LibraryRerunPhase) -> LibrarySummarySlot {
    guard kind == .transcript, hasInvocation, writesSummaryFile else {
        return LibrarySummarySlot(buttonTitle: nil, spinning: false, status: nil)
    }
    let title = hasSummary ? "Re-run summary" : "Summarize"
    switch phase {
    case .idle: return LibrarySummarySlot(buttonTitle: title, spinning: false, status: nil)
    case .running: return LibrarySummarySlot(buttonTitle: nil, spinning: true, status: "Summarizing…")
    case .failed(let why):
        return LibrarySummarySlot(buttonTitle: title, spinning: false, status: "Summary failed — \(why)")
    }
}
