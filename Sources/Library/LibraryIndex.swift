import Foundation

// MARK: - library index (what got transcribed/summarized, grouped by day)

/// One saved artifact: a transcript with its sibling summary/audio, or a day's digest.
struct LibraryEntry: Equatable {
    enum Kind: String { case transcript, digest }
    var day: String // "2026-07-15"
    var time: String? // "10:30" — nil for a digest
    var title: String? // "project kickoff" — nil when the file is unnamed
    var kind: Kind
    var url: URL
    var summaryURL: URL? // transcript rows: the same-stem summary, if one exists
    var audioURL: URL? // transcript rows: the same-stem audio (wav/m4a), if kept
}

/// A day's entries: digest first, then transcripts newest-first. Days come newest-first.
struct LibraryDay: Equatable {
    var day: String
    var entries: [LibraryEntry]
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
    for t in mdFiles(transcriptsDir, exts: ["md"]) {
        guard !stem(t).hasSuffix("-sum"),   // side-by-side summaries live in this tree — not transcripts
              let p = parseLibraryStem(stem(t)) else { continue }
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
    let days = byDay.keys.sorted(by: >).prefix(limitDays)
    return days.map { day in
        let entries = byDay[day]!.sorted { a, b in
            if (a.kind == .digest) != (b.kind == .digest) { return a.kind == .digest } // digest first
            return (a.time ?? "") > (b.time ?? "") // then newest first
        }
        return LibraryDay(day: day, entries: entries)
    }
}

/// The rows a search filter keeps: case-insensitive match on title/day/time; blank keeps everything.
/// Days with no surviving entry disappear. Pure + selftested (the window's list is just this).
func libraryFiltered(_ days: [LibraryDay], filter: String) -> [LibraryDay] {
    let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
    guard !f.isEmpty else { return days }
    return days.compactMap { day in
        let kept = day.entries.filter {
            ($0.title ?? "").lowercased().contains(f) || $0.day.contains(f)
                || ($0.time ?? "").contains(f) || $0.kind.rawValue.contains(f)
        }
        return kept.isEmpty ? nil : LibraryDay(day: day.day, entries: kept)
    }
}
