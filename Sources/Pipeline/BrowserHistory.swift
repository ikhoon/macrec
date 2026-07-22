import Foundation

// MARK: - browser history as a day-capture source (pure core + a read-only I/O shell)
//
// The daily digest today fuses meeting transcripts + summaries. A day is more than its meetings —
// what you READ and researched is signal too (the maintainer asked for browser history). This reads
// the local browser history databases READ-ONLY (immutable open — never a write, never a lock on the
// live browser), for ONE local day, and formats the visits into a compact markdown block the digest
// can cat alongside the transcripts. Opt-in; on-device; nothing leaves the machine that a summary
// run wouldn't already send. Chrome/Arc store WebKit time (µs since 1601-01-01 UTC); Safari stores
// CFAbsoluteTime (s since 2001-01-01 UTC) — both converted here, both pinned by selftests.

/// A visited page (already day-filtered by the query). `visits` counts same-URL hits in the window.
struct BrowsingVisit: Equatable {
    var url: String
    var title: String
    var visits: Int
}

/// Chrome/Chromium `last_visit_time` is microseconds since 1601-01-01 UTC. Pure.
func chromeMicros(for date: Date) -> Int64 {
    // 1601→1970 is 11_644_473_600 s; add the Unix time, to microseconds.
    Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
}

/// Safari `visit_time` is CFAbsoluteTime: seconds since 2001-01-01 UTC. Pure.
func safariSeconds(for date: Date) -> Double {
    date.timeIntervalSince1970 - 978_307_200
}

/// The [start, end) micro-second bounds of a local `yyyy-MM-dd` day, or nil if unparsable. Pure.
func dayBounds(_ day: String, calendar: Calendar = .current) -> (start: Date, end: Date)? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"
    guard let start = f.date(from: day),
          let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
    return (start, end)
}

/// The Chrome query for a day window — visit counts per URL, most-visited first. Pure (param-free
/// via string interpolation is safe here: the bounds are integers we computed, not user text).
func chromeHistoryQuery(startMicros: Int64, endMicros: Int64, limit: Int = 200) -> String {
    "SELECT urls.url, urls.title, COUNT(*) AS c FROM visits JOIN urls ON urls.id = visits.url "
        + "WHERE visits.visit_time >= \(startMicros) AND visits.visit_time < \(endMicros) "
        + "GROUP BY urls.id ORDER BY c DESC, visits.visit_time DESC LIMIT \(limit);"
}

/// The Safari query for a day window. Pure.
func safariHistoryQuery(startSeconds: Double, endSeconds: Double, limit: Int = 200) -> String {
    "SELECT i.url, v.title, COUNT(*) AS c FROM history_visits v "
        + "JOIN history_items i ON i.id = v.history_item "
        + "WHERE v.visit_time >= \(startSeconds) AND v.visit_time < \(endSeconds) "
        + "GROUP BY i.id ORDER BY c DESC, v.visit_time DESC LIMIT \(limit);"
}

/// The registrable-ish host of a URL for grouping ("https://mail.google.com/x" → "mail.google.com").
/// Pure — falls back to the raw string when there's no host.
func browsingHost(_ url: String) -> String {
    guard let h = URLComponents(string: url)?.host else { return url }
    return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
}

/// Sum visit counts for the same URL across sources (Chrome/Arc/Safari can each return it), keeping
/// the first non-empty title and the busiest-first order. Pure.
func mergeVisits(_ visits: [BrowsingVisit]) -> [BrowsingVisit] {
    var order: [String] = []
    var byURL: [String: BrowsingVisit] = [:]
    for v in visits {
        if var cur = byURL[v.url] {
            cur.visits += v.visits
            if cur.title.trimmingCharacters(in: .whitespaces).isEmpty { cur.title = v.title }
            byURL[v.url] = cur
        } else {
            order.append(v.url); byURL[v.url] = v
        }
    }
    return order.map { byURL[$0]! }.sorted { $0.visits > $1.visits }
}

/// The day's visits → a compact markdown block grouped by host (busiest host first, then by visit
/// count), or nil when there's nothing. Titles are trimmed; a missing title falls back to the host.
/// `maxPerHost` caps the noise from a single site. Pure + selftested.
func browsingMarkdown(_ visits: [BrowsingVisit], day: String, maxPerHost: Int = 5) -> String? {
    let cleaned = visits.filter { !$0.url.isEmpty && $0.url.hasPrefix("http") }
    guard !cleaned.isEmpty else { return nil }
    var byHost: [String: [BrowsingVisit]] = [:]
    var order: [String] = []
    for v in cleaned {
        let h = browsingHost(v.url)
        if byHost[h] == nil { order.append(h) }
        byHost[h, default: []].append(v)
    }
    // Busiest host first (total visits), stable by first-seen for ties.
    let hostTotals = order.map { h in (h, byHost[h]!.reduce(0) { $0 + $1.visits }) }
    let ranked = hostTotals.enumerated().sorted { a, b in
        a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset
    }.map(\.element.0)

    var lines = ["## Browsing — \(day)", ""]
    for h in ranked {
        let items = byHost[h]!.sorted { $0.visits > $1.visits }.prefix(maxPerHost)
        lines.append("- **\(h)**")
        for v in items {
            let title = v.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = title.isEmpty ? h : title
            lines.append("  - \(label)\(v.visits > 1 ? " (\(v.visits)×)" : "")")
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

// MARK: - I/O shell (read-only sqlite over an immutable copy)

enum BrowserHistory {
    static var safariPath: String { NSHomeDirectory() + "/Library/Safari/History.db" }

    /// Every Chromium history DB present: Chrome AND Arc, across profile dirs (Default, Profile N) —
    /// they share the schema and the WebKit-µs epoch, so one query shape covers all. Existence
    /// filtered here; a missing browser simply contributes nothing.
    static func chromiumHistoryPaths(fm: FileManager = .default) -> [String] {
        let base = NSHomeDirectory() + "/Library/Application Support/"
        let roots = ["Google/Chrome", "Arc/User Data", "BraveSoftware/Brave-Browser",
                     "Microsoft Edge", "Chromium"]
        var paths: [String] = []
        for root in roots {
            let dir = base + root
            let profiles = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for p in profiles where p == "Default" || p.hasPrefix("Profile ") {
                let db = "\(dir)/\(p)/History"
                if fm.fileExists(atPath: db) { paths.append(db) }
            }
        }
        return paths
    }

    /// Query one day's visits from a history DB via `sqlite3` in IMMUTABLE read-only mode (never
    /// locks or writes the live browser's file). Returns [] on any error (missing db, locked, no
    /// sqlite3) — a day-capture source must never break the digest. `parse` splits the runner's
    /// pipe-delimited rows.
    static func query(dbPath: String, sql: String,
                      run: (String) -> String? = shellQuery) -> [BrowsingVisit] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else { return [] }
        // Snapshot the DB (+ its -wal/-shm) to a temp copy and read the copy: a live open with
        // immutable=1 skips the WAL and misses today's visits, and a non-immutable open contends
        // with the browser's writes. Copying leaves the live files untouched and lets SQLite replay
        // the WAL on our own copy.
        let tmp = fm.temporaryDirectory.appendingPathComponent("macrec-hist-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let copy = tmp.appendingPathComponent("db")
        do { try fm.copyItem(atPath: dbPath, toPath: copy.path) } catch { return [] }
        for ext in ["-wal", "-shm"] where fm.fileExists(atPath: dbPath + ext) {
            try? fm.copyItem(atPath: dbPath + ext, toPath: copy.path + ext)
        }
        let cmd = "/usr/bin/sqlite3 -readonly -separator '\u{1f}' " + shq(copy.path) + " " + shq(sql)
        guard let out = run(cmd) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\u{1f}")
            guard f.count >= 3, let c = Int(f[2]) else { return nil }
            return BrowsingVisit(url: f[0], title: f[1], visits: c)
        }
    }

    /// The whole day's browsing across installed browsers → a markdown block, or nil when empty.
    static func dayMarkdown(_ day: String, calendar: Calendar = .current) -> String? {
        guard let (start, end) = dayBounds(day, calendar: calendar) else { return nil }
        let chromeSQL = chromeHistoryQuery(startMicros: chromeMicros(for: start),
                                           endMicros: chromeMicros(for: end))
        var visits = chromiumHistoryPaths().flatMap { query(dbPath: $0, sql: chromeSQL) }
        visits += query(dbPath: safariPath,
                        sql: safariHistoryQuery(startSeconds: safariSeconds(for: start),
                                                endSeconds: safariSeconds(for: end)))
        return browsingMarkdown(mergeVisits(visits), day: day)
    }

    private static func shellQuery(_ command: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
