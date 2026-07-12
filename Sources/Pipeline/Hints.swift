import AppKit
import AVFoundation
import Compression
import EventKit
import Foundation

// MARK: - transcription hints (a proper-noun dictionary biases recognition toward YOUR vocabulary)
//
// whisper's initial prompt (--prompt) steers decoding toward the given tokens — team/product names,
// domain jargon, attendee names stop coming out mangled. Merged from three sources: the Settings terms,
// an external file (git-manageable), and optionally the overlapping calendar event.

/// Split a hints blob into terms: comma- or newline-separated, trimmed. A `#` starts a comment that
/// runs to the END OF THE LINE — commas inside a comment must not resurrect its tail as terms
/// (review finding: "# old, stuff" leaked "stuff" into prompts).
func parseHintTerms(_ text: String) -> [String] {
    text.split(separator: "\n")
        .map { line in line.firstIndex(of: "#").map { String(line[..<$0]) } ?? String(line) }
        .flatMap { $0.split(separator: ",") }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

/// Merge hint sources in priority order, dedupe case-insensitively, cap the count (whisper's prompt
/// window is small — past ~60 terms the tail is ignored anyway). Pure + testable.
func mergeHintTerms(direct: [String], file: [String], event: [String], cap: Int = 60) -> [String] {
    var seen = Set<String>(), out: [String] = []
    for t in direct + file + event where out.count < cap {
        let k = t.lowercased()
        if !seen.contains(k) { seen.insert(k); out.append(t) }
    }
    return out
}

/// Assemble the effective hints prompt for a recording window from prefs (+ calendar when enabled).
func transcriptionHints(start: Date, end: Date) -> String {
    let direct = parseHintTerms(Pref.explicit(Pref.hintsTerms, "MR_HINTS"))
    var file: [String] = []
    let fp = Pref.explicit(Pref.hintsFile, "MR_HINTS_FILE").trimmingCharacters(in: .whitespacesAndNewlines)
    if !fp.isEmpty {
        let path = (fp as NSString).expandingTildeInPath
        if let txt = try? String(contentsOfFile: path, encoding: .utf8) { file = parseHintTerms(txt) }
        else { elog("hints: couldn't read \(path) — skipping the file terms") }
    }
    var event: [String] = []
    if Pref.bool(Pref.hintsCalendar, "MR_HINTS_CALENDAR", false), let e = CalendarLookup.match(start: start, end: end) {
        event = [e.title] + e.attendees
    }
    return mergeHintTerms(direct: direct, file: file, event: event).joined(separator: ", ")
}
