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
    // Transcript stamps: parsing, the clock→offset decision, and the seek-link scheme.
    check("transcript: stamp parsing accepts the saved shape, rejects whisper ranges/garbage",
          transcriptLineStamp("[14:01:12] Me: hi")?.clockSeconds == 50472
              && transcriptLineStamp("[00:00:00]")?.length == 10
              && transcriptLineStamp("[14:01:12.500 --> 14:01:14.000] raw whisper") == nil
              && transcriptLineStamp("[25:00:00] x") == nil
              && transcriptLineStamp("[14:61:00] x") == nil
              && transcriptLineStamp("14:01:12 no bracket") == nil
              && transcriptLineStamp("[hh:mm:ss] x") == nil
              && transcriptLineStamp("") == nil)
    check("transcript: clock→offset — normal, before start → 0, across midnight",
          transcriptSeekOffset(lineSeconds: 50472, startSeconds: 50400) == 72     // 14:01:12 in a 14:00 file
              && transcriptSeekOffset(lineSeconds: 50398, startSeconds: 50400) == 0 // 13:59:58 stamped early
              && transcriptSeekOffset(lineSeconds: 300, startSeconds: 85800) == 900 // 23:50 file, 00:05 line
              && libraryStartSeconds("14:00") == 50400 && libraryStartSeconds(nil) == nil
              && libraryStartSeconds("1400") == nil && libraryStartSeconds("24:00") == nil)
    check("transcript: macrec-seek links round-trip; foreign/negative/garbage parse nil",
          macrecSeekLink(offsetSeconds: 72.4)?.absoluteString == "macrec-seek:72"
              && macrecSeekSeconds(URL(string: "macrec-seek:72")!) == 72
              && macrecSeekSeconds("macrec-seek:0") == 0
              && macrecSeekSeconds(URL(string: "https://example.com")!) == nil
              && macrecSeekSeconds("macrec-seek:-5") == nil
              && macrecSeekSeconds("macrec-seek:abc") == nil
              && MarkdownRender.resolveLink("macrec-seek:12", baseURL: nil) == nil) // never a normal link
    // Stamp → link rendering: minted only when the caller passes the recording's start clock.
    do {
        func linkAt(_ s: NSAttributedString, _ needle: String) -> URL? {
            let r = (s.string as NSString).range(of: needle)
            guard r.location != NSNotFound else { return nil }
            return s.attribute(.link, at: r.location, effectiveRange: nil) as? URL
        }
        let tmd = "## Transcript\n\n[14:01:12] Me: kickoff begins\n[13:59:58] Me: stamped early"
        let linked = MarkdownRender.render(tmd, transcriptStart: 50400)
        check("markdown: transcript stamps become macrec-seek links only with a start clock",
              linkAt(linked, "[14:01:12]")?.absoluteString == "macrec-seek:72"
                  && linkAt(linked, "[13:59:58]")?.absoluteString == "macrec-seek:0"
                  && linked.string.contains("Me: kickoff begins")
                  && linkAt(MarkdownRender.render(tmd), "[14:01:12]") == nil)
    }
    // Export conversions — realistic-shaped fixture lines, invented content only.
    do {
        let srtIn = """
        # 2026-03-02 10:00–11:00 — project kickoff

        - Time: 2026-03-02 10:00–11:00 (60 min)

        ## Transcript

        [10:00:05] Me: kickoff starts
        [10:00:12] Them: agenda first?
        [10:01:00] Me: closing note
        """
        let wantSRT = """
        1
        00:00:05,000 --> 00:00:12,000
        Me: kickoff starts

        2
        00:00:12,000 --> 00:01:00,000
        Them: agenda first?

        3
        00:01:00,000 --> 00:01:05,000
        Me: closing note
        """ + "\n"
        check("export: SRT cues chain to the next line, last runs +5 s, speaker prefix kept",
              transcriptToSRT(srtIn, start: 36000) == wantSRT)
        let vtt = transcriptToVTT(srtIn, start: 36000)
        check("export: VTT carries the header and dot-millis clocks",
              vtt.hasPrefix("WEBVTT\n\n00:00:05.000 --> 00:00:12.000\nMe: kickoff starts\n")
                  && vtt.contains("00:01:00.000 --> 00:01:05.000") && !vtt.contains(","))
        let edge = transcriptCues("[10:00:05] Me: a\n[10:00:05] Them: b\nprose\n[10:00:20] Me: c",
                                  startSeconds: 36000)
        let anchored = transcriptCues("[10:00:05] Me: a\n[10:00:09] Them: b", startSeconds: nil)
        let wrapped = transcriptCues("[23:59:58] Me: a\n[00:00:06] Them: b", startSeconds: 85800)
        check("export: cue edges — same-second keeps 1 s, prose carries no cue, nil start anchors at 0, midnight wraps",
              edge == [TranscriptCue(start: 5, end: 6, text: "Me: a"),
                       TranscriptCue(start: 5, end: 20, text: "Them: b"),
                       TranscriptCue(start: 20, end: 25, text: "Me: c")]
                  && anchored.first?.start == 0 && anchored.last?.start == 4
                  && wrapped == [TranscriptCue(start: 598, end: 606, text: "Me: a"),
                                 TranscriptCue(start: 606, end: 611, text: "Them: b")])
        let plainIn = """
        # 2026-03-02 14:00 — project kickoff
        > a note
        - bullet **bold** and `code`
        [audio](../a/x.wav) plus https://example.com/page
        | Owner | Item |
        |---|---|
        | alex | plan |
        ```
        raw fence art
        ```
        [14:01:12] Me: *emphasis* stays readable
        """
        let plain = transcriptToPlainText(plainIn)
        check("export: plain text strips markdown, keeps text, lists and stamps",
              plain.contains("2026-03-02 14:00 — project kickoff") && !plain.contains("# ")
                  && plain.contains("a note") && !plain.contains("> ")
                  && plain.contains("- bullet bold and code")
                  && plain.contains("audio plus https://example.com/page")
                  && plain.contains("| Owner | Item |") && !plain.contains("|---|")
                  && plain.contains("raw fence art") && !plain.contains("```")
                  && plain.contains("[14:01:12] Me: emphasis stays readable")
                  && transcriptExportContent(plainIn, format: .markdown, startSeconds: nil) == plainIn)
    }
    // The preview-header decisions: one pure function per control (enablement IS the action).
    check("library: summary slot — hidden unless a transcript + built-in summary + an invocation",
          librarySummarySlot(kind: .transcript, hasInvocation: true, writesSummaryFile: true,
                             hasSummary: true, phase: .idle)
              == LibrarySummarySlot(buttonTitle: "Re-run summary", spinning: false, status: nil)
              && librarySummarySlot(kind: .transcript, hasInvocation: true, writesSummaryFile: true,
                                    hasSummary: false, phase: .idle).buttonTitle == "Summarize"
              && librarySummarySlot(kind: .transcript, hasInvocation: true, writesSummaryFile: true,
                                    hasSummary: true, phase: .running)
              == LibrarySummarySlot(buttonTitle: nil, spinning: true, status: "Summarizing…")
              && librarySummarySlot(kind: .transcript, hasInvocation: true, writesSummaryFile: true,
                                    hasSummary: true, phase: .failed("not logged in")).status
              == "Summary failed — not logged in"
              && librarySummarySlot(kind: .digest, hasInvocation: true, writesSummaryFile: true,
                                    hasSummary: false, phase: .idle).buttonTitle == nil
              && librarySummarySlot(kind: .audio, hasInvocation: true, writesSummaryFile: true,
                                    hasSummary: false, phase: .idle)
              == LibrarySummarySlot(buttonTitle: nil, spinning: false, status: nil)
              && librarySummarySlot(kind: .transcript, hasInvocation: false, writesSummaryFile: true,
                                    hasSummary: true, phase: .idle).buttonTitle == nil
              && librarySummarySlot(kind: .transcript, hasInvocation: true, writesSummaryFile: false,
                                    hasSummary: true, phase: .idle).buttonTitle == nil
              && librarySummarySlot(kind: nil, hasInvocation: false, writesSummaryFile: false,
                                    hasSummary: false, phase: .idle).buttonTitle == nil
              && libraryExportEnabled(.transcript) && !libraryExportEnabled(.digest)
              && !libraryExportEnabled(.audio) && !libraryExportEnabled(nil))
    // Header-action wiring, driven like a user (scenario-style: the holes live in the wiring).
    do {
        let lw = LibraryWindow.shared
        let fix = libraryFixtureDays()
        // Prefs OFF (the ephemeral store's default): no slot anywhere; Export tracks the row kind.
        lw.loadFixtureForTest(fix)   // selects the rich transcript row
        let offHidden = lw.rerunButtonTitleForTest == nil && lw.exportEnabledForTest
        lw.selectForTest(fix[0].entries[0])   // digest
        let digestOff = lw.rerunButtonTitleForTest == nil && !lw.exportEnabledForTest
        // Built-in summary mode: the slot appears on transcript rows only, titled by summary presence.
        Pref.d.set("summary", forKey: Pref.postProcessMode)
        lw.selectForTest(fix[0].entries[1])   // transcript with a summary
        let ready = lw.rerunButtonTitleForTest == "Re-run summary" && !lw.rerunSpinningForTest
            && lw.rerunStatusForTest == nil
        lw.selectForTest(fix[0].entries[2])   // transcript without one
        let readyNoSum = lw.rerunButtonTitleForTest == "Summarize"
        lw.selectForTest(fix[0].entries[0])   // digest — still hidden with the mode on
        let digestOn = lw.rerunButtonTitleForTest == nil
        let layoutOK = lw.layoutIssues().isEmpty   // the widened strip still lays out cleanly
        check("library: export/re-run enablement derives from the row + prefs (one decision)",
              offHidden && digestOff && ready && readyNoSum && digestOn && layoutOK)

        func pump(_ cond: () -> Bool) {
            let deadline = Date().addingTimeInterval(2)
            while !cond(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
        // A run: spinner while running; success rescans and keeps the user's place on the row.
        lw.selectForTest(fix[0].entries[1])
        var ranCmd: String?
        lw.runCommandForTest = { cmd, done in ranCmd = cmd; done(0) }
        lw.rerunClickForTest()
        let spinning = lw.rerunSpinningForTest && lw.rerunButtonTitleForTest == nil
            && lw.rerunStatusForTest == "Summarizing…"
        pump { !lw.rerunSpinningForTest }
        let succeeded = lw.rerunButtonTitleForTest == "Re-run summary" && lw.rerunStatusForTest == nil
            && lw.openEnabledForTest   // the selection survived the refresh
            && (ranCmd?.contains("library-fixture") ?? false)
        // A failing run: the reason (the runner's own words, from its .partial) lands in the header.
        let out = summaryOutputPath(transcriptPath: fix[0].entries[1].url.path, outDir: "")
        lw.runCommandForTest = { _, done in
            try? "fixture: not logged in".write(toFile: out + ".partial", atomically: true, encoding: .utf8)
            done(1)
        }
        lw.rerunClickForTest()
        pump { !lw.rerunSpinningForTest && lw.rerunStatusForTest != nil }
        let failed = lw.rerunStatusForTest == "Summary failed — fixture: not logged in"
            && lw.rerunButtonTitleForTest == "Re-run summary"   // retry stays one click away
            && !FileManager.default.fileExists(atPath: out + ".partial")   // the orphan was reaped
        check("library: re-run summary — spinner while running, refresh keeps the place, failure names the reason",
              spinning && succeeded && failed)
        lw.runCommandForTest = nil
        SummaryStatus.shared.resetForTest()
        Pref.d.removeObject(forKey: Pref.postProcessMode)
    }
    // Seek links drive the player (wiring): click → lazy-load, seek (clamped), play — muted here.
    do {
        let fm = FileManager.default
        let wav = fm.temporaryDirectory.appendingPathComponent("lib-seek-\(UUID().uuidString).wav")
        if let w = try? SourceWriter(url: wav),
           let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
           let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16000) {
            buf.frameLength = 16000
            for i in 0..<16000 { buf.floatChannelData![0][i] = sinf(Float(i) * 0.13) * 0.2 }
            w.append(buf)   // exactly 1 s
        }
        let lw = LibraryWindow.shared
        lw.selectForTest(LibraryEntry(day: "2026-03-02", time: "14:00", title: "project kickoff",
                                      kind: .transcript, url: URL(fileURLWithPath: "/tmp/library-fixture.md"),
                                      summaryURL: nil, audioURL: wav))
        lw.primePlayerForTest()
        lw.mutePlayerForTest()
        let seeked = lw.clickLinkForTest(URL(string: "macrec-seek:600")!)
        let clamped = lw.playerTimeForTest > 0.5 && lw.playerPlayingForTest // 600 s clamps into the 1 s file
        let foreign = !lw.clickLinkForTest(URL(string: "https://example.com/x")!)
        let zero = lw.clickLinkForTest("macrec-seek:0") && lw.playerTimeForTest < 0.5
        lw.selectForTest(nil)
        check("library: a stamp click loads, seeks (clamped) and plays; foreign links fall through",
              seeked && clamped && foreign && zero && !lw.playerActiveForTest)
        try? fm.removeItem(at: wav)
        LibraryWindow.shared.loadFixtureForTest(libraryFixtureDays())   // restore the rich default
    }
}
