import AppKit
import Foundation

/// Fixture days for the layout/snapshot harness — invented names only (public-repo rule: never a
/// real meeting title, host, or org identifier in a fixture).
func libraryFixtureDays() -> [LibraryDay] {
    let u = URL(fileURLWithPath: "/tmp/library-fixture.md")
    return [
        LibraryDay(day: "2026-03-02", entries: [
            LibraryEntry(day: "2026-03-02", time: nil, title: nil, kind: .digest, url: u,
                         summaryURL: nil, audioURL: nil),
            LibraryEntry(day: "2026-03-02", time: "14:00", title: "project kickoff", kind: .transcript,
                         url: u, summaryURL: u, audioURL: u),
            LibraryEntry(day: "2026-03-02", time: "10:30", title: "daily standup", kind: .transcript,
                         url: u, summaryURL: nil, audioURL: nil),
        ]),
        LibraryDay(day: "2026-03-01", entries: [
            LibraryEntry(day: "2026-03-01", time: "16:00", title: nil, kind: .transcript,
                         url: u, summaryURL: nil, audioURL: u),
        ]),
    ]
}

func librarySelftests(_ check: (String, Bool) -> Void) {
    // Stem parsing — every real shape in the vault, plus the garbage that must not crash the scan.
    let full = parseLibraryStem("2026-03-02-1030-project-kickoff")
    let bare = parseLibraryStem("2026-03-02-1030")
    let digest = parseLibraryStem("2026-03-02")
    let range = parseLibraryStem("2026-03-02-0855-0900") // a HHMM-HHMM name reads as a title
    check("library: stem parsing (title, bare time, digest, ranged, garbage)",
          full?.day == "2026-03-02" && full?.time == "10:30" && full?.title == "project kickoff"
              && bare?.time == "10:30" && bare?.title == nil
              && digest?.time == nil && digest?.title == nil
              && range?.title == "0900"
              && parseLibraryStem("notes") == nil
              && parseLibraryStem("2026-3-2-bad") == nil
              && parseLibraryStem("2026-03-02-abc") == nil)
    // Dir resolution mirrors the pipeline's fallback chain: empty summary dir → beside transcripts;
    // empty digest dir → beside summaries.
    let r1 = libraryRoots(transcripts: "/t", summaryOut: "", dailyOut: "", audioDir: "/a")
    let r2 = libraryRoots(transcripts: "/t", summaryOut: "/s", dailyOut: "", audioDir: "/a")
    let r3 = libraryRoots(transcripts: "/t", summaryOut: "/s", dailyOut: "/d", audioDir: "/a")
    check("library: output-dir fallback chain matches the pipeline",
          r1.summaries == "/t" && r1.daily == "/t"
              && r2.summaries == "/s" && r2.daily == "/s"
              && r3.daily == "/d")
    // Scan over a real (temp) tree: month subdirs, root-level files, same-stem and "-sum" summaries,
    // audio pairing, digest joining its day, foreign files ignored.
    do {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mr-lib-\(UUID().uuidString)")
        let t = root.appendingPathComponent("t/2026-03"), s = root.appendingPathComponent("s/2026-03")
        let d = root.appendingPathComponent("d/2026-03"), a = root.appendingPathComponent("a/2026-03")
        for dir in [t, s, d, a] { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        func touch(_ dir: URL, _ name: String) { fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("x".utf8)) }
        touch(t, "2026-03-02-1030-daily-standup.md")
        touch(t, "2026-03-02-1400-project-kickoff.md")
        touch(t, "2026-03-02-1500-side-by-side.md")
        touch(t, "2026-03-02-1500-side-by-side-sum.md") // summaryOut="" style — a summary, not a transcript
        touch(t, "stray-notes.md") // no date — ignored
        touch(t.deletingLastPathComponent(), "2026-03-01-0900.md") // root-level file, older day
        touch(s, "2026-03-02-1400-project-kickoff.md") // dedicated-dir summary
        touch(d, "2026-03-02.md") // the digest
        touch(a, "2026-03-02-1400-project-kickoff.wav")
        touch(a, "2026-03-02-1030-daily-standup.m4a")
        let days = scanLibrary(transcriptsDir: root.appendingPathComponent("t"),
                               summaryDir: root.appendingPathComponent("s"),
                               dailyDir: root.appendingPathComponent("d"),
                               audioDir: root.appendingPathComponent("a"))
        let day2 = days.first
        let kickoff = day2?.entries.first { $0.title == "project kickoff" }
        let standup = day2?.entries.first { $0.title == "daily standup" }
        check("library: scan pairs transcripts with summaries/audio, digests join their day, strays skipped",
              days.count == 2
                  && days.first?.day == "2026-03-02" && days.last?.day == "2026-03-01"
                  && day2?.entries.first?.kind == .digest // digest sorts first
                  && day2?.entries.count == 4 // digest + 3 transcripts ("-sum" not among them)
                  && kickoff?.summaryURL != nil && kickoff?.audioURL != nil
                  && standup?.summaryURL == nil && standup?.audioURL != nil
                  && days.last?.entries.count == 1 && days.last?.entries.first?.title == nil)
        // A side-by-side "-sum" file attaches to its transcript when summaries live beside transcripts.
        let side = scanLibrary(transcriptsDir: root.appendingPathComponent("t"),
                               summaryDir: root.appendingPathComponent("t"),
                               dailyDir: nil, audioDir: nil)
        let sideEntry = side.first?.entries.first { $0.title == "side by side" }
        check("library: a '-sum' sibling is the transcript's summary, never its own row",
              sideEntry?.summaryURL?.lastPathComponent == "2026-03-02-1500-side-by-side-sum.md")
        try? fm.removeItem(at: root)
    }
    // Row/label decisions.
    let fix = libraryFixtureDays()
    check("library: day labels and row text",
          libraryDayLabel(day: "2026-03-02", today: "2026-03-02", yesterday: "2026-03-01") == "Today — 2026-03-02"
              && libraryDayLabel(day: "2026-03-01", today: "2026-03-02", yesterday: "2026-03-01") == "Yesterday — 2026-03-01"
              && libraryDayLabel(day: "2026-02-14", today: "2026-03-02", yesterday: "2026-03-01") == "2026-02-14"
              && libraryRowText(fix[0].entries[0]) == "Daily digest"
              && libraryRowText(fix[0].entries[1]) == "14:00  project kickoff  ✓ summary"
              && libraryRowText(fix[1].entries[0]) == "16:00  (untitled)")
    check("library: filter keeps matching rows and drops empty days",
          libraryFiltered(fix, filter: "kickoff").count == 1
              && libraryFiltered(fix, filter: "kickoff").first?.entries.count == 1
              && libraryFiltered(fix, filter: "").count == 2
              && libraryFiltered(fix, filter: "digest").first?.entries.first?.kind == .digest
              && libraryFiltered(fix, filter: "zzz").isEmpty)
    // Layout guard, same class of check as the Settings panes: nothing collapsed, nothing overlapping.
    LibraryWindow.shared.loadFixtureForTest(libraryFixtureDays())
    let issues = LibraryWindow.shared.layoutIssues()
    check("library: no window control is collapsed or overlapping", issues.isEmpty)
    for i in issues { elog("selftest: \(i)") }
}
