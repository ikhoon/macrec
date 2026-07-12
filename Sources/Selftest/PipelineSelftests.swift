import AppKit
import AVFoundation
import EventKit
import Foundation

func pipelineSelftests(_ check: (String, Bool) -> Void) {
    // Transcription hints: parsing (comma/newline/#comment), case-insensitive dedupe, cap.
    check("hints: parse comma/newline + comments",
          parseHintTerms("Kubernetes, gRPC\n# note\n김철수\n\n") == ["Kubernetes", "gRPC", "김철수"])
    check("hints: comment runs to end of line (commas inside don't leak) + inline comment",
          parseHintTerms("# old, stuff\nAlpha # trailing, note\nBeta") == ["Alpha", "Beta"])
    // Transcript-level echo suppression — cases lifted from the user's real screenshot.
    check("echo text: exact copy suppressed",
          isLikelyEcho(mine: "Over time, I got better at finding it.",
                       theirs: "Over time, I got better at finding it."))
    check("echo text: garbled copy suppressed",   // a garbled mic copy shares ≥80% of its tokens
          isLikelyEcho(mine: "I wasn't very very find the award in the beginning, but I",
                       theirs: "I wasn't very good at finding north in the beginning, but I additioned a fair amount, and so my dad kept asking me, which way is north?"))
    check("echo text: unrelated line kept",
          !isLikelyEcho(mine: "That's like a one of my life.",
                        theirs: "Not just by how far my life has come since then, but..."))
    check("echo text: short reply never eaten",
          !isLikelyEcho(mine: "Yes.", theirs: "Yes.") && !isLikelyEcho(mine: "네 네 네", theirs: "네 네 네 알겠습니다"))
    let echoMerged: [(start: Double, who: String, text: String)] = [
        (10, "상대", "Over time, I got better at finding it."),
        (12, "나", "Over time, I got better at finding it."),     // echo → dropped
        (14, "나", "완전히 다른 내 얘기를 길게 하고 있어요"),         // genuine → kept
        (40, "나", "Over time, I got better at finding it."),     // outside ±8 s → kept
    ]
    let echoOut = suppressEchoLines(echoMerged, mine: "나")
    check("echo text: merged transcript drops only the in-window copy",
          echoOut.map { $0.start } == [10, 14, 40])
    // Recording schedule: day parsing (ranges incl. wrap), hour ranges (lunch gap), isActive.
    check("schedule: day parsing",
          RecordSchedule.parseDays("mon-fri") == [2, 3, 4, 5, 6]
          && RecordSchedule.parseDays("MON, wed,fri") == [2, 4, 6]
          && RecordSchedule.parseDays("sat-mon") == [7, 1, 2]      // wraps the week
          && RecordSchedule.parseDays("nope, mon") == [2]          // junk skipped
          && RecordSchedule.parseDays("") == [])
    check("schedule: hour-range parsing",
          RecordSchedule.parseRanges("10:00-12:00, 13:00-19:00").map { [$0.start, $0.end] } == [[600, 720], [780, 1140]]
          && RecordSchedule.parseRanges("23:00-24:00").map { [$0.start, $0.end] } == [[1380, 1440]]
          && RecordSchedule.parseRanges("garbage, 25:00-26:00, 10:00-10:00").isEmpty)   // invalid/empty skipped
    check("schedule: pasted dashes + overnight wrap",
          RecordSchedule.parseRanges("10:00–12:00").map { [$0.start, $0.end] } == [[600, 720]]      // en dash
          && RecordSchedule.parseRanges("13:00~19:00").map { [$0.start, $0.end] } == [[780, 1140]]  // tilde range
          && RecordSchedule.parseDays("mon–fri") == [2, 3, 4, 5, 6]
          && RecordSchedule.parseRanges("22:00-06:00").map { [$0.start, $0.end] } == [[1320, 1440], [0, 360]])
    check("schedule: invalid input detected (never silently records 24/7)",
          !RecordSchedule.hoursValid("10am-7pm") && !RecordSchedule.hoursValid("10:00-10:00")
          && RecordSchedule.hoursValid("10:00–12:00, 13:00~19:00") && RecordSchedule.hoursValid("")
          && !RecordSchedule.daysValid("mon-frii") && RecordSchedule.daysValid("mon–fri") && RecordSchedule.daysValid(""))
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    func schedDate(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utc.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"; return f.date(from: s)!
    }
    let sched = RecordSchedule.from(enabled: true, days: "mon-fri", hours: "10:00-12:00, 13:00-19:00")
    check("schedule: mon-fri work hours minus lunch",
          sched.isActive(at: schedDate("2026-07-06 10:00"), calendar: utc)      // Mon 10:00 → on
          && !sched.isActive(at: schedDate("2026-07-06 12:30"), calendar: utc)  // lunch gap → off
          && sched.isActive(at: schedDate("2026-07-06 18:59"), calendar: utc)
          && !sched.isActive(at: schedDate("2026-07-06 19:00"), calendar: utc)  // end is exclusive
          && !sched.isActive(at: schedDate("2026-07-05 11:00"), calendar: utc)) // Sunday → off
    check("schedule: disabled = always on; half-filled form never stops recording",
          RecordSchedule.from(enabled: false, days: "", hours: "").isActive(at: schedDate("2026-07-05 03:00"), calendar: utc)
          && RecordSchedule.from(enabled: true, days: "mon-fri", hours: "").isActive(at: schedDate("2026-07-06 03:00"), calendar: utc)
          && RecordSchedule.from(enabled: true, days: "", hours: "10:00-11:00").isActive(at: schedDate("2026-07-05 10:30"), calendar: utc))
    // Menu hover: a view-backed item gets NO native highlight — MenuHoverView must provide
    // the selection pill + notify the label restyle, and reset when the menu reopens.
    do {
        let hv = MenuHoverView(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        var hoverStates: [Bool] = []
        hv.onHover = { hoverStates.append($0) }
        let initiallyOff = !hv.highlightVisibleForTest
        hv.setHover(true)
        let litAndNotified = hv.highlightVisibleForTest && hoverStates == [true]
        hv.setHover(false)
        let offAgain = !hv.highlightVisibleForTest && hoverStates == [true, false]
        check("menu hover: pill shows on hover, hides after, restyle notified",
              initiallyOff && litAndNotified && offAgain)
        check("menu hover: tracking area installed (mouse enter/exit will arrive)",
              hv.trackingReadyForTest)
    }
    // Transcribe-now push: terminal statuses notify (the menu may be closed by then),
    // transient ones keep waiting — a dangling flag would mis-attribute the NEXT hourly segment.
    // Post-processing was invisible: it ran, left nothing behind, and the app read as broken.
    let stamp = schedDate("2026-07-07 12:03")
    let hm: (Date) -> String = { d in let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
                                     f.timeZone = utc.timeZone; f.dateFormat = "HH:mm"; return f.string(from: d) }
    check("tray: the summary row names the state, the file and when it happened",
          summaryMenuTitle(.off, hm: hm) == "Summaries: off"
          && summaryMenuTitle(.idle, hm: hm) == "Summary: after the next transcript"
          && summaryMenuTitle(.running("a.md"), hm: hm) == "Summary: running… a.md"
          && summaryMenuTitle(.done("a.md", stamp), hm: hm) == "Summary: a.md · 12:03"
          && summaryMenuTitle(.failed("a.md", stamp, reason: "Not logged in"), hm: hm)
             == "Summary FAILED: a.md · 12:03")
    // A row that is clickable must DO something. Enablement and the click read one decision, so
    // they cannot disagree — clicking a failure explains it, never nothing.
    // A freeform shell hook writes nowhere we know: nothing to reveal, no partial to reap.
    check("summary: only the built-in summary mode writes a file we can reveal or reap",
          postProcessWritesSummaryFile(.summary)
          && !postProcessWritesSummaryFile(.shell)
          && !postProcessWritesSummaryFile(.off)
          && summaryRowAction(.done("a.md", stamp), lastOutput: nil) == .none)   // shell mode
    check("tray: the summary row's click always has an outcome, and a failure explains itself",
          summaryRowAction(.failed("a.md", stamp, reason: "Not logged in · Please run /login"), lastOutput: nil)
          == .explain("a.md", "Not logged in · Please run /login")
          && summaryRowAction(.failed("a.md", stamp, reason: nil), lastOutput: "/s/old.md")
          == .explain("a.md", nil)                        // failure wins over a stale old file
          && summaryRowAction(.done("a.md", stamp), lastOutput: "/s/a.md") == .reveal("/s/a.md")
          && summaryRowAction(.idle, lastOutput: nil) == .none
          && summaryRowAction(.off, lastOutput: "/s/a.md") == .none)
    // The runner writes STDOUT to `<out>.partial` and only then promotes it, so its error message
    // lands INSIDE that file, never on stderr. `claude` exiting 1 with "Not logged in" left only
    // "exit 1" in the log, and the orphaned .partial piled up in the notes vault for days.
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("macrec-reap-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let outPath = tmp.appendingPathComponent("2026-07-10-1030-standup.md").path
    try? "Not logged in · Please run /login\n".write(toFile: outPath + ".partial", atomically: true, encoding: .utf8)
    let reason = reapFailedPostProcess(outPath: outPath)
    let orphanGone = !FileManager.default.fileExists(atPath: outPath + ".partial")
    let noReason = reapFailedPostProcess(outPath: tmp.appendingPathComponent("absent.md").path)
    // Blank leading lines must not be mistaken for "no reason"; a runner that streamed megabytes
    // before dying must not be slurped whole; invalid UTF-8 must not throw the reason away.
    let blankPath = tmp.appendingPathComponent("blank.md").path
    try? "\n\n   \nreal reason here\n".write(toFile: blankPath + ".partial", atomically: true, encoding: .utf8)
    let skipsBlanks = reapFailedPostProcess(outPath: blankPath) == "real reason here"
    let emptyPath = tmp.appendingPathComponent("empty.md").path
    try? "".write(toFile: emptyPath + ".partial", atomically: true, encoding: .utf8)
    let emptyIsNil = reapFailedPostProcess(outPath: emptyPath) == nil
    let emptyGone = !FileManager.default.fileExists(atPath: emptyPath + ".partial")
    let hugePath = tmp.appendingPathComponent("huge.md").path
    try? ("error first\n" + String(repeating: "x", count: 5_000_000))
        .write(toFile: hugePath + ".partial", atomically: true, encoding: .utf8)
    let hugeOK = reapFailedPostProcess(outPath: hugePath) == "error first"
    let badPath = tmp.appendingPathComponent("bad.md").path
    try? Data([0xFF, 0xFE, 0x0A] + Array("boom".utf8)).write(to: URL(fileURLWithPath: badPath + ".partial"))
    let badOK = reapFailedPostProcess(outPath: badPath) != nil   // lossy decode, not a crash or nil
    try? FileManager.default.removeItem(at: tmp)
    check("summary: a failed runner's reason is read back from its .partial, which is then removed",
          reason == "Not logged in · Please run /login" && orphanGone && noReason == nil
          && skipsBlanks && emptyIsNil && emptyGone && hugeOK && badOK)
    // The marker used to be stamped BEFORE the run. A login error at 20:00 then marked the day
    // done, and the digest never retried — exactly what happened on 2026-07-09 and 07-10.
    check("digest: only a run that wrote a file (or can never succeed today) retires the day",
          digestMarksDayDone(.wrote)
          && digestMarksDayDone(.nothingToDo)      // no meetings — retrying finds none either
          && digestMarksDayDone(.wouldOverwrite)   // the name collides until the user changes it
          && !digestMarksDayDone(.runnerFailed))   // no login / no network — retry on the next tick
    check("tray: the digest row says off, due, or already written today",
          digestMenuTitle(enabled: false, dueTime: "20:00", lastRun: "", today: "2026-07-07")
          == "Daily digest: off"
          && digestMenuTitle(enabled: true, dueTime: "20:00", lastRun: "", today: "2026-07-07")
          == "Daily digest: due at 20:00"
          && digestMenuTitle(enabled: true, dueTime: "20:00", lastRun: "2026-07-07", today: "2026-07-07")
          == "Daily digest: written today"
          && digestMenuTitle(enabled: true, dueTime: "20:00", lastRun: "2026-07-06", today: "2026-07-07")
          == "Daily digest: due at 20:00")
    // A summary that ran must be reachable: the row is only clickable once it produced a file.
    SummaryStatus.shared.resetForTest()
    let noOutput = SummaryStatus.shared.lastOutput == nil && SummaryStatus.shared.current == .idle
    SummaryStatus.shared.started("a.md")
    let running = SummaryStatus.shared.current == .running("a.md")
    SummaryStatus.shared.finished("a.md", at: stamp, output: "/s/a.md")
    check("tray: summary status tracks running → done and remembers the file it wrote",
          noOutput && running
          && SummaryStatus.shared.current == .done("a.md", stamp)
          && SummaryStatus.shared.lastOutput == "/s/a.md")
    // The row reads BOTH halves under one lock. Reading them separately let a failure land between
    // the two, so the row offered to reveal a file for the run that had just failed.
    SummaryStatus.shared.failed("b.md", at: stamp, reason: "boom")
    let (act, out) = SummaryStatus.shared.snapshot
    check("tray: a failure carries its reason all the way to the row's click",
          summaryRowAction(act, lastOutput: out) == .explain("b.md", "boom")
          && out == "/s/a.md"                       // a stale success path is still remembered…
          && summaryRowAction(act, lastOutput: out) != .reveal("/s/a.md"))   // …but never offered
    SummaryStatus.shared.resetForTest()
    // The row is a control, and a control wired to nothing looks perfect until you click it.
    check("tray: the summary row's reveal action is implemented",
          AppController.instancesRespond(to: Selector(("revealLastSummary"))))
    // …and menuWillOpen must actually REFRESH those rows. Drive the real menu: a deleted
    // refreshPostProcessRows() call would leave both titles empty, and this check red.
    // Pin the mode: with no saved pref (a fresh machine, and CI) the effective mode is .off and the
    // row reads "Summaries: off", which says nothing about whether menuWillOpen refreshed it.
    let savedMode = Pref.d.object(forKey: Pref.postProcessMode)
    Pref.d.set(PostProcessMode.summary.rawValue, forKey: Pref.postProcessMode)
    SummaryStatus.shared.resetForTest()
    SummaryStatus.shared.failed("z.md", at: stamp, reason: "runner exploded")
    let rows = AppController().postProcessRowsAfterMenuOpenForTest()
    check("tray: opening the menu refreshes the post-process rows from live status",
          rows != nil
          && rows!.summary.contains("z.md")               // the live failure, not the built-in empty title
          && rows!.digest.hasPrefix("Daily digest"))
    if let savedMode { Pref.d.set(savedMode, forKey: Pref.postProcessMode) }
    else { Pref.d.removeObject(forKey: Pref.postProcessMode) }
    // A row with nothing to show must be GREY after AppKit's validation pass, not merely after
    // our own `isEnabled = false`. The menu auto-enables items, so validateMenuItem has the last
    // word — assigning isEnabled and reading it straight back was a test asserting itself.
    SummaryStatus.shared.resetForTest()   // .idle, no output → the row can do nothing
    let idleRows = AppController().postProcessRowsAfterMenuOpenForTest()
    check("tray: a summary row with nothing to reveal is disabled after AppKit re-validates it",
          idleRows != nil && idleRows!.enabled == false)
    check("flush push: terminal statuses classified, transient ones wait",
          flushOutcome(for: "Saved: 2026-07-05-2100-2130.md")! == ("Transcript ready", "2026-07-05-2100-2130.md")
          && flushOutcome(for: "No speech — discarded") != nil
          && flushOutcome(for: "No speech — skipped") != nil
          && flushOutcome(for: "Downloading model — transcription deferred") != nil
          && flushOutcome(for: "Transcription failed") != nil
          // Every status `process` can END on must classify, or "Transcribe now" hangs on its
          // spinner and the still-armed flag steals the next segment's notification.
          && flushOutcome(for: "No meeting · short — skipped") != nil
          && flushOutcome(for: "Transcribing…") == nil
          && flushOutcome(for: "Recording · mic + system audio") == nil
          && flushOutcome(for: "Paused (locked/asleep)") == nil)
    check("flush push: spinner holds to a visible minimum, never negative",
          abs(spinnerHold(elapsed: 0.3) - 0.7) < 1e-9
          && spinnerHold(elapsed: 1.0) == 0
          && spinnerHold(elapsed: 45) == 0
          && spinnerHold(elapsed: 0) == 1.0)
    // L3 daily digest: due-logic (deadline + once-a-day marker = sleep catch-up), input
    // preference (summary over transcript, matched by basename), path fallbacks, invocation.
    check("digest: due after deadline, once per day, junk time never fires",
          dailyDigestDue(now: schedDate("2026-07-07 20:01"), time: "20:00", lastRun: "", calendar: utc)
          && !dailyDigestDue(now: schedDate("2026-07-07 19:59"), time: "20:00", lastRun: "", calendar: utc)
          && !dailyDigestDue(now: schedDate("2026-07-07 20:01"), time: "20:00", lastRun: "2026-07-07", calendar: utc)
          && dailyDigestDue(now: schedDate("2026-07-08 23:00"), time: "20:00", lastRun: "2026-07-07", calendar: utc)
          && !dailyDigestDue(now: schedDate("2026-07-07 20:01"), time: "25:99", lastRun: "", calendar: utc))
    check("digest: inputs prefer the summary, fall back to the transcript, day-filtered + sorted",
          dailyDigestInputs(day: "2026-07-07",
                            transcripts: ["/t/2026-07-07-1400.md", "/t/2026-07-06-1000.md", "/t/2026-07-07-1000-standup.md"],
                            summaries: ["/s/2026-07-07-1000-standup.md"])
          == ["/s/2026-07-07-1000-standup.md", "/t/2026-07-07-1400.md"])
    // A digest lands in the SAME month folder as the day's notes, and `2026-07-07.md` carries the
    // very day-prefix the input filter matches — without the exclusion it would feed itself its
    // own previous output. Compared by standardized path (`/t/./x.md` is the same file as `/t/x.md`).
    check("digest: the digest we're about to write is never one of its own inputs",
          dailyDigestInputs(day: "2026-07-07",
                            transcripts: ["/t/2026-07/./2026-07-07.md", "/t/2026-07/2026-07-07-1000-standup.md"],
                            summaries: ["/t/2026-07/2026-07-07.md"],
                            excluding: "/t/2026-07/2026-07-07.md")
          == ["/t/2026-07/2026-07-07-1000-standup.md"])
    // The name is the user's to choose: default is a bare date, tokens expand, a missing
    // extension is added, and a blank or `/`-bearing template can't produce a nameless file
    // or escape the month folder.
    check("digest: file name comes from a user template, defaults to {date}.md",
          dailyDigestFileName(day: "2026-07-07") == "2026-07-07.md"
          && dailyDigestFileName(day: "2026-07-07", template: "") == "2026-07-07.md"
          && dailyDigestFileName(day: "2026-07-07", template: "{date}-daily") == "2026-07-07-daily.md"
          && dailyDigestFileName(day: "2026-07-07", template: ".md") == "2026-07-07.md"
          && dailyDigestFileName(day: "2026-07-07", template: "../{date}.md") == "..-2026-07-07.md")
    // A template with no {date} resolved to one path for the whole month, and the digest is
    // promoted with `mv` — every day silently overwrote the day before.
    check("digest: a name without {date} still gets the day, so days can't overwrite each other",
          dailyDigestFileName(day: "2026-07-07", template: "notes.md") == "2026-07-07-notes.md"
          && dailyDigestFileName(day: "2026-07-07", template: "digest-{month}.md") == "2026-07-07-digest-2026-07.md")
    // A summary saved next to its transcript is `<base>-sum.md`; keying on the raw basename meant
    // the digest never found it and quietly fed on the raw transcript instead.
    check("digest: a `-sum` summary next to its transcript is matched to that transcript",
          dailyDigestInputs(day: "2026-07-07",
                            transcripts: ["/t/2026-07-07-1000-standup.md"],
                            summaries: ["/t/2026-07-07-1000-standup-sum.md"])
          == ["/t/2026-07-07-1000-standup-sum.md"])
    // No `Daily/` tree any more — we only ever create the month folder under the dir the user
    // picked; choosing where that folder lives is the user's job, not ours.
    check("digest: output path — <picked dir>/YYYY-MM/<name>, no injected Daily folder",
          dailyDigestOutputPath(day: "2026-07-07", outDir: "/d", summaryOutDir: "/r/Summaries", transcriptsDir: "/r/Transcripts")
          == "/d/2026-07/2026-07-07.md"
          && dailyDigestOutputPath(day: "2026-07-07", outDir: "", summaryOutDir: "/r/Summaries", transcriptsDir: "/r/Transcripts")
          == "/r/Summaries/2026-07/2026-07-07.md"
          && dailyDigestOutputPath(day: "2026-07-07", outDir: "", summaryOutDir: "", transcriptsDir: "/r/Transcripts")
          == "/r/Transcripts/2026-07/2026-07-07.md"
          && dailyDigestOutputPath(day: "2026-07-07", outDir: "/d", summaryOutDir: "", transcriptsDir: "/r/T",
                                   nameTemplate: "{date}-daily.md") == "/d/2026-07/2026-07-07-daily.md")
    check("digest: invocation cats inputs into the runner with atomic promote",
          dailyDigestInvocation(runner: .claude, prompt: "P", inputs: ["/s/a.md", "/s/b's.md"], outPath: "/d/2026-07/x.md")
          == "mkdir -p '/d/2026-07' && cat '/s/a.md' '/s/b'\\''s.md' | claude -p 'P' "
           + "> '/d/2026-07/x.md.partial' && mv '/d/2026-07/x.md.partial' '/d/2026-07/x.md'"
          && dailyDigestInvocation(runner: .claude, prompt: "P", inputs: [], outPath: "/d/x.md") == nil)
    // Tail-scheduler decision — both timing regressions ("not real-time" = timer wait,
    // "second line slow" = firing while another request was in flight) lived here.
    check("live: tail fire decision (one in flight, only when moved, never after final)",
          shouldFireTailTranslation(tail: "새 꼬리", lastSent: "", inFlight: false, final: false)
          && !shouldFireTailTranslation(tail: "같음", lastSent: "같음", inFlight: false, final: false)
          && !shouldFireTailTranslation(tail: "새 꼬리", lastSent: "옛", inFlight: true, final: false)
          && !shouldFireTailTranslation(tail: "새 꼬리", lastSent: "", inFlight: false, final: true)
          && !shouldFireTailTranslation(tail: "", lastSent: "옛", inFlight: false, final: false))
    // Rendering must stay IN ORDER while sentence translations land async: part 2 landing
    // before part 1 must NOT display until part 1 arrives; the volatile tail renders last.
    if #available(macOS 26, *) {
        var cl = LiveCaptions.CapLine(speaker: "나", text: "a. b. c", final: false, time: Date())
        cl.transParts = [nil, "TWO"]
        cl.transTail = "tail"
        let outOfOrderHidden = cl.translated == "tail"        // part 2 waits for part 1
        cl.transParts = ["ONE", "TWO"]
        let ordered = cl.translated == "ONE TWO tail"
        cl.transTail = nil
        let frozen = cl.translated == "ONE TWO"
        check("live: translation renders in order (late part 1 gates part 2; tail last)",
              outOfOrderHidden && ordered && frozen)
    }
    // Live translation streams per COMPLETED sentence — the splitter must not fire on
    // decimals or on a trailing period that hasn't been confirmed by a following space.
    check("live: sentence splitter (decimals safe, tail waits, hard punct immediate)",
          completeSentences("안녕하세요. 오늘 회의는") == ["안녕하세요."]
          && completeSentences("3.5 퍼센트입니다. 다음 안건은") == ["3.5 퍼센트입니다."]
          && completeSentences("됐나요? 정말요! 네.") == ["됐나요?", "정말요!"]
          && completeSentences("아직 문장이 안 끝났") == []
          && completeSentences("First point. Second point here") == ["First point."])
    // Update check: dotted-numeric compare (string compare says "0.10" < "0.9").
    check("update: version compare handles multi-digit, v-prefix, unequal lengths",
          isNewerVersion("v0.6.0", than: "0.5.0")
          && isNewerVersion("0.10.0", than: "0.9.9")
          && isNewerVersion("1.0", than: "0.99.99")
          && !isNewerVersion("v0.5.0", than: "0.5.0")
          && !isNewerVersion("0.5", than: "0.5.0")
          && !isNewerVersion("0.4.9", than: "0.5.0"))
    // File naming: start time only (the end time lived in the name briefly — clutter).
    check("naming: transcript base is the start time only",
          transcriptBaseName(start: schedDate("2026-07-05 21:00"), timeZone: utc.timeZone) == "2026-07-05-2100"
          && transcriptBaseName(start: schedDate("2026-07-05 23:50"), timeZone: utc.timeZone) == "2026-07-05-2350")
    // A mapped meeting stamps the transcript with the MEETING's start, clamped to the recorded
    // window: a 21:10 meeting inside the 21:00 rotation slice files as 21:10, while the second
    // hour of a 20:30 meeting still files as 21:00 — otherwise both slices of one long meeting
    // would claim 20:30, collapse onto the same name, and the later one would overwrite the first.
    let segA = schedDate("2026-07-05 21:00"), segAEnd = schedDate("2026-07-05 22:00")
    check("naming: a mapped calendar event stamps its own start, clamped to the recorded window",
          transcriptStart(segStart: segA, segEnd: segAEnd, eventStart: nil) == segA
          && transcriptStart(segStart: segA, segEnd: segAEnd,
                             eventStart: schedDate("2026-07-05 21:10")) == schedDate("2026-07-05 21:10")
          && transcriptStart(segStart: segA, segEnd: segAEnd,
                             eventStart: schedDate("2026-07-05 20:30")) == segA          // continuation slice
          && transcriptStart(segStart: segA, segEnd: segAEnd,
                             eventStart: schedDate("2026-07-05 22:30")) == segAEnd       // matched on the +60s window
          && transcriptBaseName(start: transcriptStart(segStart: segA, segEnd: segAEnd,
                                                       eventStart: schedDate("2026-07-05 21:10")),
                                timeZone: utc.timeZone) == "2026-07-05-2110")
    // Naming an hour of audio after a calendar event: the 2026-07-08 15:00–16:02 segment was
    // titled after an event it shared 2 minutes with, because that event carried a Zoom
    // URL, while the kickoff that filled 60 of its 62 minutes had none. A link means "online",
    // not "this is the meeting you recorded"; it may only break a tie.
    let seg = schedDate("2026-07-08 15:00"), segEnd = schedDate("2026-07-08 16:02")
    let kickoff = EventCandidate(title: "project kickoff",         // 60 min of the segment
                                 start: schedDate("2026-07-08 14:00"),
                                 end: schedDate("2026-07-08 16:00"), hasLink: false)
    let goalCheck = EventCandidate(title: "goal progress check",     // 2 min
                                   start: schedDate("2026-07-08 16:00"),
                                   end: schedDate("2026-07-08 17:00"), hasLink: true)
    let nextDay = EventCandidate(title: "caught only by the ±padding",  // zero true overlap
                                 start: schedDate("2026-07-08 16:02"),
                                 end: schedDate("2026-07-08 17:00"), hasLink: true)
    func pick(_ cs: [EventCandidate]) -> String? {
        bestEventIndex(segStart: seg, segEnd: segEnd, candidates: cs).map { cs[$0].title }
    }
    // Same-overlap tie: the online meeting wins. Both cover 15:00–16:00 exactly.
    let inPerson = EventCandidate(title: "in person", start: seg,
                                  end: schedDate("2026-07-08 16:00"), hasLink: false)
    let online = EventCandidate(title: "online", start: seg,
                                end: schedDate("2026-07-08 16:00"), hasLink: true)
    check("calendar: the event that FILLS the segment wins; a meeting link only breaks a tie",
          pick([goalCheck, kickoff]) == "project kickoff"              // link no longer outranks
          && pick([kickoff, goalCheck]) == "project kickoff"           // and order can't flip it
          && pick([nextDay]) == nil                                    // zero overlap → no match
          && pick([kickoff, nextDay]) == "project kickoff"
          && pick([inPerson, online]) == "online"                      // tie → the online one
          && pick([online, inPerson]) == "online"
          && pick([]) == nil
          && eventOverlap(kickoff, segStart: seg, segEnd: segEnd) == 3600
          && eventOverlap(goalCheck, segStart: seg, segEnd: segEnd) == 120)
    // Calendar-gated recording: record only while a meeting is live (± padding), composed with the schedule.
    let mtg = [EventCandidate(title: "sync", start: schedDate("2026-07-08 10:00"),
                              end: schedDate("2026-07-08 11:00"), hasLink: true)]
    check("calendar gate: half-open [start, end) ± padding, real events only",
          meetingActiveNow(mtg, now: schedDate("2026-07-08 10:30"), padding: 0)              // mid-meeting
          && meetingActiveNow(mtg, now: schedDate("2026-07-08 10:00"), padding: 0)            // AT start → active
          && !meetingActiveNow(mtg, now: schedDate("2026-07-08 11:00"), padding: 0)           // AT end → not (half-open)
          && !meetingActiveNow(mtg, now: schedDate("2026-07-08 09:30"), padding: 0)           // before
          && meetingActiveNow(mtg, now: schedDate("2026-07-08 09:55"), padding: 300)          // exactly start − 5-min pad
          && !meetingActiveNow(mtg, now: schedDate("2026-07-08 09:54"), padding: 300)         // one min earlier → out
          && !meetingActiveNow(mtg, now: schedDate("2026-07-08 11:05"), padding: 300)         // exactly end + pad → not
          && !meetingActiveNow([], now: schedDate("2026-07-08 10:30"), padding: 0)            // no events → never
          && meetingActiveNow(mtg, now: schedDate("2026-07-08 10:30"), padding: -600)         // negative pad clamped to 0
          && !meetingActiveNow([EventCandidate(title: "pt", start: schedDate("2026-07-08 10:00"),
                                               end: schedDate("2026-07-08 10:00"), hasLink: false)],
                               now: schedDate("2026-07-08 10:00"), padding: 60))              // zero-duration event ignored
    check("recording window: each gate blocks independently; both-off admits all",
          recordingWindowActive(scheduleEnabled: false, scheduleActive: false, calendarGated: false, meetingActive: false)   // both off → yes
          && recordingWindowActive(scheduleEnabled: true, scheduleActive: true, calendarGated: true, meetingActive: true)    // both pass → yes
          && !recordingWindowActive(scheduleEnabled: true, scheduleActive: false, calendarGated: true, meetingActive: true)  // schedule blocks (calendar passes)
          && !recordingWindowActive(scheduleEnabled: true, scheduleActive: true, calendarGated: true, meetingActive: false)  // calendar blocks (schedule passes)
          && recordingWindowActive(scheduleEnabled: true, scheduleActive: true, calendarGated: false, meetingActive: false)  // calendar off → schedule only
          && recordingWindowActive(scheduleEnabled: false, scheduleActive: false, calendarGated: true, meetingActive: true)) // schedule off → calendar only
    // Dead-mic detection — the jack-input incident: hours of segments "voiced" by clicks
    // (energy-gate trips) while containing zero speech-length runs, all discarded silently.
    check("mic guard: speech-run accounting (clicks never qualify, speech does)",
          speechlikeFrames(Array(repeating: 0.5, count: 799) + [0.0]) == 0        // 49.9 ms — just under
          && speechlikeFrames(Array(repeating: 0.5, count: 800)) == 800           // 50 ms run qualifies fully
          && speechlikeFrames(Array(repeating: 0.5, count: 1200)) == 1200
          && speechlikeFrames((0..<8000).map { $0 % 100 < 8 ? 0.5 : 0.0 }) == 0   // click train
          && speechlikeFrames(Array(repeating: 0.5, count: 900) + Array(repeating: 0.0, count: 100)
                              + Array(repeating: 0.5, count: 900)) == 1800)       // two syllables
    check("mic guard: dead-input verdict (energy without speech runs)",
          micLooksDead(voiced: 44.1, speech: 0.1)      // the real incident segment
          && !micLooksDead(voiced: 22.4, speech: 8.0)  // real speech
          && !micLooksDead(voiced: 3.0, speech: 0.0)   // quiet hour — no verdict
          && !micLooksDead(voiced: 6.0, speech: 0.6))  // borderline but speech present
    // Hallucination scrubbing — the exact failure classes from our junk transcripts:
    // a broadcast hour where one sentence repeated for 15 minutes, YouTube-outro
    // boilerplate on quiet rooms, "oh oh oh…" degeneration. Real speech must survive.
    check("scrub: boilerplate + within-line loop dropped, real speech kept",
          Transcriber.isHallucinatedLine("ご視聴ありがとうございました")
          && Transcriber.isHallucinatedLine("시청해 주셔서 감사합니다.")
          && Transcriber.isHallucinatedLine("Thanks for watching!")
          && Transcriber.isHallucinatedLine(Array(repeating: "oh,", count: 28).joined(separator: " "))
          && !Transcriber.isHallucinatedLine("이번 스프린트에 배포 파이프라인 마이그레이션을 마무리하기로 했습니다.")
          && !Transcriber.isHallucinatedLine("네, 네. 알겠습니다.")
          && !Transcriber.isHallucinatedLine("Let's start with the deployment status update."))
    // Review-verified false-positive victims that MUST survive: short real repetition
    // (backchannels, chants) under the 80-byte gate; sentences that merely MENTION
    // boilerplate phrases (anchored match, not contains).
    check("scrub: real Korean repetition + boilerplate mentions survive",
          !Transcriber.isHallucinatedLine("네, 네, 네, 네, 네, 네, 네, 네, 네.")
          && !Transcriber.isHallucinatedLine("파이팅 파이팅 파이팅 파이팅 파이팅")
          && !Transcriber.isHallucinatedLine("Thank you for watching the demo, any questions before we move on?")
          && !Transcriber.isHallucinatedLine("구독과 좋아요 버튼 위치를 바꾸는 A/B 테스트를 해 보죠."))
    check("scrub: dominant 4-gram loop detected, varied prose passes",
          Transcriber.maxNgramShare(Array(repeating: "you should be able to get the ball", count: 8).joined(separator: " ")) > 0.1
          && Transcriber.maxNgramShare("the quick brown fox jumps over the lazy dog while the calm river flows past the quiet village near the tall mountain") <= 0.06)
    do {
        // The observed 15-minute loop: one sentence every ~3 s for 240 lines. Collapses to
        // its first occurrence; identical REAL repeats far apart (>30 s) are both kept.
        let loop = (0..<240).map { (10.0 + Double($0) * 3, "You should be able to get the ball from the right side.") }
        let lines = [(5.0, "회의 시작하겠습니다.")] + loop + [(950.0, "다음 주제로 넘어가죠.")]
        let (kept, dropped) = Transcriber.scrubLines(lines)
        check("scrub: 240-line repetition loop collapses to one, neighbors survive",
              kept.map { $0.1 } == ["회의 시작하겠습니다.",
                                    "You should be able to get the ball from the right side.",
                                    "다음 주제로 넘어가죠."] && dropped == 239)
        let farApart = [(10.0, "네."), (500.0, "네.")]
        check("scrub: identical backchannels far apart both survive",
              Transcriber.scrubLines(farApart).kept.count == 2)
    }
    check("scrub: compression ratio separates loops from prose",
          Transcriber.compressionRatio(String(repeating: "구독과 좋아요 부탁드립니다 ", count: 12)) > 2.4
          && Transcriber.compressionRatio("오늘 논의된 내용은 세 가지였고 각각 담당자가 다음 주까지 정리하기로 했습니다.") < 2.4)
    // Audio archive tiers: raw → compressed → deleted, with 0 disabling a stage.
    check("audio tiers: raw → compressed → deleted (0 = never/forever)",
          AudioArchivePolicy(rawDays: 7, totalDays: 90).tier(ageDays: 3) == .raw
          && AudioArchivePolicy(rawDays: 7, totalDays: 90).tier(ageDays: 7) == .compressed
          && AudioArchivePolicy(rawDays: 7, totalDays: 90).tier(ageDays: 90) == .deleted
          && AudioArchivePolicy(rawDays: 0, totalDays: 90).tier(ageDays: 60) == .raw          // never compress
          && AudioArchivePolicy(rawDays: 7, totalDays: 0).tier(ageDays: 400) == .compressed   // keep forever
          && AudioArchivePolicy(rawDays: 30, totalDays: 14).tier(ageDays: 20) == .deleted)    // delete wins
    check("audio tiers: retention combo text parsing",
          AudioArchivePolicy.parseRetentionDays("90 days") == 90
          && AudioArchivePolicy.parseRetentionDays("1 year") == 365
          && AudioArchivePolicy.parseRetentionDays("6 months") == 180
          && AudioArchivePolicy.parseRetentionDays("2 weeks") == 14
          && AudioArchivePolicy.parseRetentionDays("45") == 45
          && AudioArchivePolicy.parseRetentionDays("Unlimited") == 0
          && AudioArchivePolicy.parseRetentionDays("Don't compress") == 0
          && AudioArchivePolicy.parseRetentionDays("soon") == nil
          && AudioArchivePolicy.parseRetentionDays("") == nil
          && AudioArchivePolicy.parseRetentionDays("9223372036854775807 years") == nil)  // typed live: red, not a trap
    check("audio tiers: titles round-trip through the parser",
          [7, 90, 180, 365, 730, 0].allSatisfy {
              AudioArchivePolicy.parseRetentionDays(AudioArchivePolicy.retentionTitle($0)) == $0
          })
    // Real afconvert round-trip — would have caught 64 kbps being rejected ('!dat') at 16 kHz
    // mono. Also proves the retention clock survives archiving (mdate carried over).
    do {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("macrec-selftest-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("tone.wav"), m4a = dir.appendingPathComponent("tone.m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]
        if let file = try? AVAudioFile(forWriting: wav, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false),
           let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16000) {
            buf.frameLength = 16000
            for i in 0..<16000 { buf.floatChannelData![0][i] = sinf(Float(i) * 0.1) * 0.3 }
            try? file.write(from: buf)
        }
        let past = Date(timeIntervalSinceNow: -86400 * 10)
        try? fm.setAttributes([.modificationDate: past], ofItemAtPath: wav.path)
        let ok = AudioArchiver.compress(wav, to: m4a)
        let size = (try? fm.attributesOfItem(atPath: m4a.path))?[.size] as? Int ?? 0
        let mdate = (try? m4a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        check("audio tiers: afconvert AAC round-trip keeps the retention clock",
              ok && size > 0 && abs(mdate.timeIntervalSince(past)) < 2)
        try? fm.removeItem(at: dir)
    }
    // nextBoundary anchors the manual-override expiry: a wall-clock timestamp, so sleeping
    // across boundaries still expires it. Fri 20:00 → next flip is MONDAY 10:00 (skips the weekend).
    check("schedule: next boundary (lunch edge, weekend skip, never-flips → nil)",
          sched.nextBoundary(after: schedDate("2026-07-06 11:00"), calendar: utc) == schedDate("2026-07-06 12:00")
          && sched.nextBoundary(after: schedDate("2026-07-06 12:30"), calendar: utc) == schedDate("2026-07-06 13:00")
          && sched.nextBoundary(after: schedDate("2026-07-10 20:00"), calendar: utc) == schedDate("2026-07-13 10:00")
          && RecordSchedule.from(enabled: false, days: "mon-fri", hours: "").nextBoundary(after: schedDate("2026-07-06 11:00"), calendar: utc) == nil
          && RecordSchedule.from(enabled: true, days: "", hours: "").nextBoundary(after: schedDate("2026-07-06 11:00"), calendar: utc) == nil)
    check("hints: dedupe (case-insensitive) + priority order",
          mergeHintTerms(direct: ["Alpha", "Beta"], file: ["alpha", "Gamma"], event: ["Beta", "김철수"])
          == ["Alpha", "Beta", "Gamma", "김철수"])
    check("hints: cap respected",
          mergeHintTerms(direct: (1...100).map(String.init), file: [], event: []).count == 60)
    // Live pass-through: Deepgram gets per-term `keywords` boosts; OpenAI gets a transcription prompt.
    let dgURL = DeepgramLiveTranscriber.listenURL(lang: "ko", keywords: ["Kubernetes", "김철수"]).absoluteString
    check("hints: deepgram keywords in the listen URL",
          dgURL.contains("keywords=Kubernetes") && dgURL.contains("keywords=") && dgURL.contains("language=ko"))
    let oaCfg = OpenAILiveTranscriber.sessionConfig(lang: "ko", hints: "Kubernetes, 김철수")
    let oaTr = (oaCfg["session"] as? [String: Any])?["input_audio_transcription"] as? [String: Any]
    let oaCfgNoHints = OpenAILiveTranscriber.sessionConfig(lang: "ko", hints: "")
    let oaTrNo = (oaCfgNoHints["session"] as? [String: Any])?["input_audio_transcription"] as? [String: Any]
    check("hints: openai transcription prompt set only when non-empty",
          (oaTr?["prompt"] as? String) == "Kubernetes, 김철수" && oaTrNo?["prompt"] == nil)
    // Gladia engine: REST-init body (language + vocabulary only when present) + transcript parsing.
    let glBody = GladiaLiveTranscriber.initBody(lang: "ko", vocabulary: ["Kubernetes"])
    let glLangs = (glBody["language_config"] as? [String: Any])?["languages"] as? [String]
    let glVocab = (((glBody["realtime_processing"] as? [String: Any])?["custom_vocabulary_config"]
                    as? [String: Any])?["vocabulary"]) as? [String]
    let glPlain = GladiaLiveTranscriber.initBody(lang: "", vocabulary: [])
    check("gladia: init body carries language + vocabulary only when present",
          glLangs == ["ko"] && glVocab == ["Kubernetes"]
          && glPlain["language_config"] == nil && glPlain["realtime_processing"] == nil
          && glPlain["sample_rate"] as? Int == 16000)
    var glGot: [(String, Bool)] = []
    let gl = GladiaLiveTranscriber(label: "t", locale: Locale(identifier: "ko-KR")) { s, f in glGot.append((s, f)) }
    gl.handle(#"{"type":"transcript","data":{"is_final":false,"utterance":{"text":" 안녕하세"}}}"#)
    gl.handle(#"{"type":"transcript","data":{"is_final":true,"utterance":{"text":"안녕하세요"}}}"#)
    gl.handle(#"{"type":"transcript","data":{"is_final":true,"utterance":{"text":"  "}}}"#)   // blank → dropped
    gl.handle(#"{"type":"audio_chunk","acknowledged":true}"#)                                  // ack → dropped
    gl.handle("junk")                                                                          // junk → dropped
    check("gladia: partial/final parsing (trimmed, junk dropped)", glGot.count == 2
          && glGot[0] == ("안녕하세", false) && glGot[1] == ("안녕하세요", true))
}
