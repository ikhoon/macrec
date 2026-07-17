import AppKit
import AVFoundation
import Foundation

/// Fixture days for the layout/snapshot harness — invented names only (public-repo rule: never a
/// real meeting title, host, or org identifier in a fixture).
func libraryFixtureDays() -> [LibraryDay] {
    let u = URL(fileURLWithPath: "/tmp/library-fixture.md")
    let a = URL(fileURLWithPath: "/tmp/library-fixture.wav")
    return [
        LibraryDay(day: "2026-03-02", entries: [
            LibraryEntry(day: "2026-03-02", time: nil, title: nil, kind: .digest, url: u,
                         summaryURL: nil, audioURL: nil),
            LibraryEntry(day: "2026-03-02", time: "14:00", title: "project kickoff", kind: .transcript,
                         url: u, summaryURL: u, audioURL: a),
            LibraryEntry(day: "2026-03-02", time: "10:30", title: "daily standup", kind: .transcript,
                         url: u, summaryURL: nil, audioURL: nil),
        ]),
        LibraryDay(day: "2026-03-01", entries: [
            LibraryEntry(day: "2026-03-01", time: "17:52", title: nil, kind: .audio, url: a,
                         summaryURL: nil, audioURL: a),
            LibraryEntry(day: "2026-03-01", time: "16:00", title: nil, kind: .transcript,
                         url: u, summaryURL: nil, audioURL: a),
            // Real titles run long and once WRAPPED over the next row (attributed text ignores the
            // field's truncation) — the fixture keeps one so the harness renders that case forever.
            LibraryEntry(day: "2026-03-01", time: "09:00",
                         title: "이번 분기 오케스트레이션 개발 워크숍 시리즈 세 번째 세션 사전 준비 회의",
                         kind: .transcript, url: u, summaryURL: u, audioURL: nil),
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
        touch(a, "2026-03-02-1400.wav") // different stem, SAME minute as the kickoff — orphan row
        touch(a, "2026-03-02-1030-daily-standup.m4a")
        touch(a, "2026-03-01-1752.m4a") // no transcript — must surface as its own audio row
        let days = scanLibrary(transcriptsDir: root.appendingPathComponent("t"),
                               summaryDir: root.appendingPathComponent("s"),
                               dailyDir: root.appendingPathComponent("d"),
                               audioDir: root.appendingPathComponent("a"))
        let day2 = days.first
        let kickoff = day2?.entries.first { $0.title == "project kickoff" }
        let standup = day2?.entries.first { $0.title == "daily standup" }
        let orphan = days.last?.entries.first { $0.kind == .audio }
        let kickoffIdx = day2?.entries.firstIndex { $0.title == "project kickoff" } ?? -1
        let sameMinuteIdx = day2?.entries.firstIndex { $0.kind == .audio && $0.time == "14:00" } ?? -1
        check("library: scan pairs transcripts with summaries/audio, digests join their day, strays skipped",
              days.count == 2
                  && days.first?.day == "2026-03-02" && days.last?.day == "2026-03-01"
                  && day2?.entries.first?.kind == .digest // digest sorts first
                  && day2?.entries.count == 5 // digest + 3 transcripts + same-minute orphan audio
                  && kickoff?.summaryURL != nil && kickoff?.audioURL != nil
                  && standup?.summaryURL == nil && standup?.audioURL != nil
                  && kickoffIdx >= 0 && sameMinuteIdx > kickoffIdx // same minute: transcript first
                  && days.last?.entries.count == 2 // 09:00 transcript + the orphan audio row
                  && orphan?.time == "17:52" && orphan?.audioURL == orphan?.url)
        // A side-by-side "-sum" file attaches to its transcript when summaries live beside transcripts.
        let side = scanLibrary(transcriptsDir: root.appendingPathComponent("t"),
                               summaryDir: root.appendingPathComponent("t"),
                               dailyDir: nil, audioDir: nil)
        let sideEntry = side.first?.entries.first { $0.title == "side by side" }
        check("library: a '-sum' sibling is the transcript's summary, never its own row",
              sideEntry?.summaryURL?.lastPathComponent == "2026-03-02-1500-side-by-side-sum.md")
        try? fm.removeItem(at: root)
    }
    // Markdown rendering — the exact shapes macrec's own documents emit, plus the garbage that
    // must degrade to plain text instead of crashing (calendar-notes art, unterminated markers).
    do {
        func fontAt(_ s: NSAttributedString, _ needle: String) -> NSFont? {
            let r = (s.string as NSString).range(of: needle)
            guard r.location != NSNotFound else { return nil }
            return s.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
        }
        func linkAt(_ s: NSAttributedString, _ needle: String) -> URL? {
            let r = (s.string as NSString).range(of: needle)
            guard r.location != NSNotFound else { return nil }
            return s.attribute(.link, at: r.location, effectiveRange: nil) as? URL
        }
        let md = """
        # Title
        ## Section
        > a note
        - bullet **bold** and `code`
          - nested
        1. numbered
        [audio](../a/x.wav) and https://example.com/page.
        -::~:~:: calendar art ::~:~::-
        plain *italic* tail
        """
        let base = URL(fileURLWithPath: "/t/2026-03/doc.md")
        let r = MarkdownRender.render(md, baseURL: base)
        let title = fontAt(r, "Title"), section = fontAt(r, "Section"), bold = fontAt(r, "bold")
        let code = fontAt(r, "code")
        check("markdown: headings scale, bold bolds, code goes mono, bullets become bullets",
              (title?.pointSize ?? 0) > (section?.pointSize ?? 0)
                  && (section?.pointSize ?? 0) > 13
                  && (bold?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
                  && (code?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false)
                  && r.string.contains("•  bullet")
                  && r.string.contains("1.  numbered")
                  && !r.string.contains("**")         // markers consumed
                  && !r.string.contains("# Title"))   // hashes consumed
        check("markdown: links resolve (relative against the doc, bare URL sans trailing dot)",
              linkAt(r, "audio")?.path == "/t/a/x.wav"
                  && linkAt(r, "example.com")?.absoluteString == "https://example.com/page"
                  && r.string.contains("page.")   // the sentence dot stayed as text
                  && MarkdownRender.resolveLink("javascript:alert(1)", baseURL: base) == nil
                  && MarkdownRender.resolveLink("https://ok.example", baseURL: nil) != nil)
        check("markdown: calendar art and unterminated markers stay plain, never crash",
              r.string.contains("-::~:~:: calendar art ::~:~::-")
                  && !MarkdownRender.render("**unterminated\n`lone tick\n*stars **everywhere",
                                            baseURL: nil).string.isEmpty
                  && MarkdownRender.render("", baseURL: nil).string.isEmpty
                  && MarkdownRender.render(String(repeating: "x", count: MarkdownRender.renderCap + 1),
                                           baseURL: nil).length > MarkdownRender.renderCap)
        let fenced = MarkdownRender.render("```\nraw -::~ art\n```\nafter", baseURL: nil)
        check("markdown: fences show verbatim mono content without the fence markers",
              fenced.string.contains("raw -::~ art") && !fenced.string.contains("```")
                  && (fontAt(fenced, "raw -::~ art")?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false))
        // Review-round regressions, pinned: CRLF files (EventKit notes / Windows-authored docs),
        // language-tagged fences, one level of parens in link URLs, the scheme allowlist, and the
        // bracket flood that made the inline regex quadratic (33 s at 40k chars before the cap).
        let crlf = MarkdownRender.render("## Notes\r\n---\r\nHello\r\n", baseURL: nil)
        check("markdown: CRLF input renders like LF (rule drawn, no stray carriage returns)",
              crlf.string.contains("──────────") && !crlf.string.utf16.contains(13)   // \r\n is ONE grapheme
                  && (fontAt(crlf, "Notes")?.pointSize ?? 0) > 13)
        let lang = MarkdownRender.render("```swift\nlet x = 1\n```", baseURL: nil)
        check("markdown: language-tagged fence is consumed, body stays mono",
              !lang.string.contains("```") && !lang.string.contains("swift")
                  && (fontAt(lang, "let x = 1")?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false))
        let paren = MarkdownRender.render("[wiki](https://mirror.example.org/wiki/Rust_(lang))", baseURL: nil)
        check("markdown: link URLs keep balanced parens; scheme allowlist admits mail/obsidian/file",
              linkAt(paren, "wiki")?.absoluteString == "https://mirror.example.org/wiki/Rust_(lang)"
                  && MarkdownRender.resolveLink("mailto:a@b.example", baseURL: nil) != nil
                  && MarkdownRender.resolveLink("obsidian://open?vault=x", baseURL: nil) != nil
                  && MarkdownRender.resolveLink("file:///tmp/x.md", baseURL: nil) != nil)
        let flooded = MarkdownRender.render(String(repeating: "[", count: 8000), baseURL: nil)
        check("markdown: a pathological bracket flood renders plain instead of hanging",
              flooded.string.contains("[[[") && flooded.length >= 8000)
        // Tables: header + separator + ragged rows become real NSTextTable blocks; a |-line
        // without a matching separator stays plain prose.
        func blocksAt(_ s: NSAttributedString, _ needle: String) -> Int {
            let r = (s.string as NSString).range(of: needle)
            guard r.location != NSNotFound,
                  let p = s.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle
            else { return -1 }
            return p.textBlocks.count
        }
        let table = MarkdownRender.render(
            "| Owner | Item |\n|---|---|\n| alex | **rollout** plan |\n| sam |\ntail prose", baseURL: nil)
        check("markdown: pipe tables become bordered table blocks, prose stays prose",
              blocksAt(table, "Owner") == 1 && blocksAt(table, "rollout") == 1
                  && !table.string.contains("|") && !table.string.contains("**")
                  && table.string.contains("tail prose") && blocksAt(table, "tail prose") == 0
                  && MarkdownRender.render("| x | y |\nno separator", baseURL: nil).string.contains("| x | y |"))
        // Task-list checkboxes — the summarizer emits action items in this shape.
        let tasks = MarkdownRender.render("- [ ] call the vendor\n- [x] send minutes", baseURL: nil)
        check("markdown: task-list items render as checkboxes",
              tasks.string.contains("☐  call the vendor") && tasks.string.contains("☑  send minutes")
                  && !tasks.string.contains("[ ]") && !tasks.string.lowercased().contains("[x]"))
    }
    check("library: player clock formatting",
          libraryClock(0) == "0:00" && libraryClock(61) == "1:01" && libraryClock(3599) == "59:59"
              && libraryClock(3600) == "1:00:00" && libraryClock(-1) == "--:--"
              && libraryClock(.nan) == "--:--")
    // Row/label decisions.
    let fix = libraryFixtureDays()
    check("library: day labels and row text",
          libraryDayLabel(day: "2026-03-02", today: "2026-03-02", yesterday: "2026-03-01") == "Today — 2026-03-02"
              && libraryDayLabel(day: "2026-03-01", today: "2026-03-02", yesterday: "2026-03-01") == "Yesterday — 2026-03-01"
              && libraryDayLabel(day: "2026-02-14", today: "2026-03-02", yesterday: "2026-03-01") == "2026-02-14"
              && libraryRowSpec(fix[0].entries[0]) == LibraryRowSpec(icon: "newspaper", tint: .orange, text: "Daily digest", trailing: [])
              && libraryRowSpec(fix[0].entries[1]) == LibraryRowSpec(icon: "text.bubble", tint: .blue, text: "14:00  project kickoff", trailing: ["sparkles", "waveform"])
              && libraryRowSpec(fix[0].entries[2]) == LibraryRowSpec(icon: "text.bubble", tint: .blue, text: "10:30  daily standup", trailing: [])
              && libraryRowSpec(fix[1].entries[0]) == LibraryRowSpec(icon: "waveform", tint: .purple, text: "17:52  (untitled)", trailing: [])
              && libraryRowSpec(fix[1].entries[1]) == LibraryRowSpec(icon: "text.bubble", tint: .blue, text: "16:00  (untitled)", trailing: ["waveform"]))
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
    // Player lifecycle WITHOUT audible playback (review P1: the whole subsystem was untested):
    // lazy load on prime, real duration on the clock, reset on row switch, a deleted file named
    // as missing, and the cleared/audio-only states laying out cleanly.
    do {
        let fm = FileManager.default
        let wav = fm.temporaryDirectory.appendingPathComponent("lib-play-\(UUID().uuidString).wav")
        if let w = try? SourceWriter(url: wav),
           let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
           let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16000) {
            buf.frameLength = 16000
            for i in 0..<16000 { buf.floatChannelData![0][i] = sinf(Float(i) * 0.13) * 0.2 }
            w.append(buf)   // exactly 1 s
        }
        var days = libraryFixtureDays()
        days[1].entries[0] = LibraryEntry(day: "2026-03-01", time: "17:52", title: nil, kind: .audio,
                                          url: wav, summaryURL: nil, audioURL: wav)
        let lw = LibraryWindow.shared
        lw.loadFixtureForTest(days)
        lw.selectForTest(days[1].entries[0])
        let audioRow = !lw.playerBarHiddenForTest && lw.docTextForTest.contains("Audio-only")
        let audioLayout = lw.layoutIssues().isEmpty
        lw.primePlayerForTest()
        let loaded = lw.playerActiveForTest && lw.clockTextForTest.hasSuffix("0:01") && lw.seekMaxForTest > 0.9
        lw.selectForTest(days[0].entries[2])   // a no-audio transcript row
        let reset = !lw.playerActiveForTest && lw.playerBarHiddenForTest
        let gone = fm.temporaryDirectory.appendingPathComponent("lib-gone-\(UUID().uuidString).wav")
        lw.selectForTest(LibraryEntry(day: "2026-03-01", time: "09:00", title: nil, kind: .audio,
                                      url: gone, summaryURL: nil, audioURL: gone))
        lw.primePlayerForTest()
        let missing = lw.clockTextForTest.contains("missing")
        lw.selectForTest(nil)
        let cleared = lw.playerBarHiddenForTest && !lw.openEnabledForTest && lw.docTextForTest.isEmpty
        check("library: player lazy-loads with real duration, resets on row switch, names a missing file",
              audioRow && audioLayout && loaded && reset && missing && cleared)
        try? fm.removeItem(at: wav)
        LibraryWindow.shared.loadFixtureForTest(libraryFixtureDays())   // restore the rich default
    }
}
