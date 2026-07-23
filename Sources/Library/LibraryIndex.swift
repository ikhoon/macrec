import Foundation

// MARK: - library index (what got transcribed/summarized, grouped by day)

/// One saved artifact: a transcript with its sibling summary/audio, a day's digest, or an audio
/// recording that has no transcript (kept audio must stay navigable even when whisper wrote nothing).
/// Hashable because these ARE the NSOutlineView items: AppKit boxes the structs and calls -hash on
/// them — Equatable-only values fall back to identity hashing and AppKit warns about severe
/// performance problems (observed live the first night the window shipped).
struct LibraryEntry: Equatable, Hashable {
    enum Kind: String { case transcript, digest, audio }
    var day: String // "2026-07-15"
    var time: String? // "10:30" — nil for a digest
    var title: String? // "project kickoff" — nil when the file is unnamed
    var kind: Kind
    var url: URL
    var summaryURL: URL? // transcript rows: the same-stem summary, if one exists
    var audioURL: URL? // the same-stem audio (wav/m4a) — on .audio rows this equals url
}

/// A day's entries: digest first, then transcripts newest-first. Days come newest-first.
/// Hashable for the same NSOutlineView-item reason as LibraryEntry.
struct LibraryDay: Equatable, Hashable {
    var day: String
    var entries: [LibraryEntry]
}

/// The files removed when a Library entry is deleted: the transcript/digest itself, its same-stem
/// summary, and its audio — BOTH the raw .wav and the archived .m4a (whichever exist), since retention
/// may have compressed one into the other. Pure + selftested; the caller filters to those that exist and
/// moves them to the Trash (recoverable). Deduped by standardized path, stable order.
func libraryDeletionSet(_ e: LibraryEntry) -> [URL] {
    var urls = [e.url]
    if e.kind == .digest {   // the #146 structured sidecar (<date>.json) sits next to the digest .md
        urls.append(e.url.deletingPathExtension().appendingPathExtension("json"))
    }
    if let s = e.summaryURL { urls.append(s) }
    if let a = e.audioURL {
        urls.append(a)
        let other = a.pathExtension.lowercased() == "wav" ? "m4a" : "wav"
        urls.append(a.deletingPathExtension().appendingPathExtension(other))
    }
    var seen = Set<String>()
    return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
}

/// The entry to select for a given file `target` — the tray "summary:" row's in-app destination.
/// A transcript row matches when the target IS its summary (so the Summary view opens on it); any row
/// matches when the target is its own file (a digest, or a summary opened by its own path). Returns the
/// row's transcript URL + kind (what `reselect` keys on). Pure + selftested; path-standardized so a
/// `/private` or symlinked path still matches.
func libraryEntryToSelect(days: [LibraryDay], target: URL) -> (url: URL, kind: LibraryEntry.Kind)? {
    let t = target.standardizedFileURL.path
    for e in days.flatMap(\.entries) where e.summaryURL?.standardizedFileURL.path == t || e.url.standardizedFileURL.path == t {
        return (e.url, e.kind)
    }
    return nil
}

/// Parse a library file STEM — "YYYY-MM-DD-HHMM[-title]" or the digest's bare "YYYY-MM-DD".
/// Hyphens in the title read as spaces for display. Returns nil for stems without a leading date
/// (stray files must never crash the scan — they are simply not library entries).
func parseLibraryStem(_ stem: String) -> (day: String, time: String?, title: String?)? {
    // Leading date: 10 chars, digits in the right places.
    guard stem.count >= 10 else { return nil }
    let chars = Array(stem)
    for i in 0..<10 {
        if i == 4 || i == 7 {
            guard chars[i] == "-" else { return nil }
        } else {
            guard chars[i].isNumber else { return nil }
        }
    }
    let day = String(chars[0..<10])
    guard stem.count > 10 else { return (day, nil, nil) }
    guard chars[10] == "-", stem.count >= 15 else { return nil }
    let hhmm = chars[11..<15]
    guard hhmm.allSatisfy(\.isNumber) else { return nil }
    let time = "\(String(hhmm.prefix(2))):\(String(hhmm.suffix(2)))"
    guard stem.count > 15 else { return (day, time, nil) }
    guard chars[15] == "-" else { return nil }
    let title = String(chars[16...]).replacingOccurrences(of: "-", with: " ")
    return (day, time, title.isEmpty ? nil : title)
}

/// Scan the configured output folders into day-grouped entries, newest day first. Reads the
/// transcript tree as truth and attaches same-stem summaries/audio; the daily digest joins its day.
/// Tolerates missing dirs, files at the root or in YYYY-MM subdirs, and foreign files.
func scanLibrary(transcriptsDir: URL, summaryDir: URL?, dailyDir: URL?, audioDir: URL?,
                 limitDays: Int = 90, fm: FileManager = .default) -> [LibraryDay] {
    func mdFiles(_ root: URL?, exts: Set<String>) -> [URL] {
        guard let root = root else { return [] }
        var out: [URL] = []
        let top = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                               options: [.skipsHiddenFiles])) ?? []
        for item in top {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let sub = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])) ?? []
                out += sub.filter { exts.contains($0.pathExtension.lowercased()) }
            } else if exts.contains(item.pathExtension.lowercased()) {
                out.append(item)
            }
        }
        return out
    }
    func stem(_ u: URL) -> String { u.deletingPathExtension().lastPathComponent }

    // A summary in a dedicated dir shares the transcript's stem; one saved NEXT TO its transcript
    // (summaryOut == "") is "<stem>-sum.md". When the summary dir IS the transcript tree, only the
    // "-sum" shape counts — otherwise every transcript would pair with itself.
    let sideBySide = summaryDir?.standardizedFileURL.path == transcriptsDir.standardizedFileURL.path
    let summaries = Dictionary(mdFiles(summaryDir, exts: ["md"]).compactMap { u -> (String, URL)? in
        let s = stem(u)
        if s.hasSuffix("-sum") { return (String(s.dropLast(4)), u) }
        return sideBySide ? nil : (s, u)
    }, uniquingKeysWith: { a, _ in a })
    let audio = Dictionary(mdFiles(audioDir, exts: ["wav", "m4a"]).map { (stem($0), $0) },
                           uniquingKeysWith: { a, _ in a })

    var byDay: [String: [LibraryEntry]] = [:]
    var pairedAudioStems = Set<String>()
    for t in mdFiles(transcriptsDir, exts: ["md"]) {
        guard !stem(t).hasSuffix("-sum"),   // side-by-side summaries live in this tree — not transcripts
              let p = parseLibraryStem(stem(t)) else { continue }
        if audio[stem(t)] != nil { pairedAudioStems.insert(stem(t)) }
        byDay[p.day, default: []].append(LibraryEntry(
            day: p.day, time: p.time, title: p.title, kind: .transcript, url: t,
            summaryURL: summaries[stem(t)], audioURL: audio[stem(t)]))
    }
    for d in mdFiles(dailyDir, exts: ["md"]) {
        guard let p = parseLibraryStem(stem(d)), p.time == nil, p.title == nil else { continue }
        byDay[p.day, default: []].append(LibraryEntry(
            day: p.day, time: nil, title: nil, kind: .digest, url: d,
            summaryURL: nil, audioURL: nil))
    }
    // Audio with no transcript gets its own row — a recording whisper wrote nothing for (or whose
    // transcript was deleted) must still be findable and playable.
    for (s, u) in audio where !pairedAudioStems.contains(s) {
        guard let p = parseLibraryStem(s) else { continue }
        byDay[p.day, default: []].append(LibraryEntry(
            day: p.day, time: p.time, title: p.title, kind: .audio, url: u,
            summaryURL: nil, audioURL: u))
    }
    let days = byDay.keys.sorted(by: >).prefix(limitDays)
    return days.map { LibraryDay(day: $0, entries: librarySortedEntries(byDay[$0]!)) }
}

/// One day's entries in list order: the daily digest first (the whole-day summary reads as the day's
/// header), then EARLIEST-to-LATEST by time (the user reads a day forward, not in reverse — a picked
/// day once came back newest-first), a transcript ahead of its same-minute audio sibling. Pure so the
/// ordering is selftested directly, not through a disk scan.
func librarySortedEntries(_ entries: [LibraryEntry]) -> [LibraryEntry] {
    entries.sorted { a, b in
        if (a.kind == .digest) != (b.kind == .digest) { return a.kind == .digest }
        if (a.time ?? "") != (b.time ?? "") { return (a.time ?? "") < (b.time ?? "") }
        return a.kind.rawValue > b.kind.rawValue
    }
}

/// The rows a filter keeps: an optional KIND scope (nil = every kind), an optional calendar DAY
/// ("yyyy-MM-dd", nil = every day — the sidebar calendar's pick), AND a case-insensitive text match
/// on title/day/time (blank = every row). All apply; days with no surviving entry disappear.
/// Pure + selftested (the window's list is just this).
func libraryFiltered(_ days: [LibraryDay], filter: String, onlyKind: LibraryEntry.Kind? = nil,
                     day onlyDay: String? = nil, content: [URL: String] = [:]) -> [LibraryDay] {
    let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
    guard !f.isEmpty || onlyKind != nil || onlyDay != nil else { return days }
    return days.compactMap { day in
        if let onlyDay, day.day != onlyDay { return nil }
        let kept = day.entries.filter { e in
            guard onlyKind == nil || e.kind == onlyKind else { return false }
            guard !f.isEmpty else { return true }
            // Metadata match (fast) OR a full-text match in the transcript/summary body (the `content`
            // map, lowercased, is built and injected by the window so this stays pure/testable).
            return (e.title ?? "").lowercased().contains(f) || e.day.contains(f)
                || (e.time ?? "").contains(f) || e.kind.rawValue.contains(f)
                || (content[e.url]?.contains(f) ?? false)
        }
        return kept.isEmpty ? nil : LibraryDay(day: day.day, entries: kept)
    }
}

/// Whether `filter` matches an entry's metadata alone (title/day/time/kind) — i.e. NOT a body-only hit.
/// The window uses this to decide when to show a content snippet (a title hit needs none). Pure.
func libraryMetadataMatches(_ e: LibraryEntry, filter: String) -> Bool {
    let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
    guard !f.isEmpty else { return true }
    return (e.title ?? "").lowercased().contains(f) || e.day.contains(f)
        || (e.time ?? "").contains(f) || e.kind.rawValue.contains(f)
}

/// A one-line preview of where `term` occurs in `body`: the matching line, whitespace-collapsed, and
/// clipped to a window of ~`context` chars on each side of the hit with … where text was trimmed.
/// Returns nil when the term isn't present. Case-insensitive. Pure + selftested (the results snippet).
func searchSnippet(_ body: String, term: String, context: Int = 40) -> String? {
    let needle = term.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return nil }
    // The matching line (collapsed whitespace so a wrapped transcript line reads as one). All index math
    // is done on `line` itself via a case-insensitive search — mixing indices from a separately-lowercased
    // copy is unsound (a case-fold can change UTF-8 length and shift or crash the slice).
    let hitLine = body.split(whereSeparator: \.isNewline)
        .first { $0.range(of: needle, options: .caseInsensitive) != nil }
    guard let hitLine else { return nil }
    let line = hitLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    guard let r = line.range(of: needle, options: .caseInsensitive) else { return line }
    let start = line.index(r.lowerBound, offsetBy: -context, limitedBy: line.startIndex) ?? line.startIndex
    let end = line.index(r.upperBound, offsetBy: context, limitedBy: line.endIndex) ?? line.endIndex
    var snip = String(line[start..<end])
    if start > line.startIndex { snip = "… " + snip }
    if end < line.endIndex { snip += " …" }
    return snip
}
