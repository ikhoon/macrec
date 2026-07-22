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
          && !digestMarksDayDone(.runnerFailed))   // no login / no network — retry with backoff
    // A failed digest retried on EVERY 30 s tick: 453 claude spawns and 453 notifications in one
    // afternoon when the CLI lost its login. Backoff bounds the retries; the notification fires once.
    check("digest: failures back off (10m, 30m, then hourly) and notify only once per streak",
          digestRetryDelay(afterFailures: 0) == 0
          && digestRetryDelay(afterFailures: 1) == 600
          && digestRetryDelay(afterFailures: 2) == 1800
          && digestRetryDelay(afterFailures: 3) == 3600 && digestRetryDelay(afterFailures: 50) == 3600
          && digestShouldNotifyFailure(consecutiveFailures: 1)
          && !digestShouldNotifyFailure(consecutiveFailures: 2)
          && !digestShouldNotifyFailure(consecutiveFailures: 453))
    // The launchd workaround (anthropics/claude-code#77213) borrows the CLI's own token from its Keychain
    // JSON: nested shape parses, an expired token is refused, junk is refused. Times are epoch-millis.
    let ccNow = Date(timeIntervalSince1970: 1_800_000_000)   // fixed clock — never the machine's
    let ccJSON = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat-TEST","expiresAt":1800000000001,"refreshToken":"r"}}"#
    let ccExpired = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat-TEST","expiresAt":1799999999999}}"#
    check("digest: claude CLI token parse — fresh nested OK, expired/malformed refused",
          claudeCliAccessToken(fromKeychainJSON: ccJSON, now: ccNow) == "sk-ant-oat-TEST"
          && claudeCliAccessToken(fromKeychainJSON: ccExpired, now: ccNow) == nil
          && claudeCliAccessToken(fromKeychainJSON: #"{"accessToken":"flat-TOK"}"#, now: ccNow) == "flat-TOK"
          && claudeCliAccessToken(fromKeychainJSON: "not json", now: ccNow) == nil
          && claudeCliAccessToken(fromKeychainJSON: #"{"claudeAiOauth":{"expiresAt":1}}"#, now: ccNow) == nil)
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
    // Digest style templates: named, unique, and every style keeps the invariants — checkbox
    // action items (so the vault can track them) and answer-in-input-language.
    check("digest templates: unique names, MINE-ONLY checkbox rule everywhere, Standard is the default",
          Set(digestPromptTemplates.map(\.name)).count == digestPromptTemplates.count
              // every template carries the mine-only rule (checkbox for me, plain bullet for others)
              && digestPromptTemplates.allSatisfy { $0.prompt.contains("- [ ] item") && $0.prompt.contains("NO checkbox") }
              && digestPromptTemplates.allSatisfy { $0.prompt.contains("same language") }
              && digestPromptTemplates.first?.prompt == defaultDailyDigestPrompt
              && defaultSummaryPrompt.contains("- [ ] item") && defaultSummaryPrompt.contains("NO checkbox")
              && digestTemplateIndex(for: defaultDailyDigestPrompt + "\n") == 0
              && digestTemplateIndex(for: "my own prompt") == nil)
    // Structured daily-log sidecar (VISION Pillar 1): path, prompt, and the VALIDATION that refuses
    // to write garbage — the one thing standing between a hallucinated reply and the queryable record.
    check("structured digest: sidecar path is the digest stem + .json",
          structuredSidecarPath(digestPath: "/v/Daily/2026-07/2026-07-20.md") == "/v/Daily/2026-07/2026-07-20.json"
              && structuredDigestPrompt(day: "2026-07-20").contains("2026-07-20")
              && structuredDigestInvocation(runner: .claude, day: "2026-07-20",
                                            digestPath: "/d/x.md", outPath: "/d/x.json").contains("'/d/x.json'.partial"))
    // Valid JSON is normalized (sorted keys, forced date) and accepted; a fenced reply is unwrapped;
    // parse failure, wrong top-level type, and a mistyped collection field are all REJECTED (nil).
    let good = validateStructuredDigest(
        "{\"date\":\"1999-01-01\",\"decisions\":[{\"text\":\"ship it\"}],\"actionItems\":[],\"meetings\":[],\"entities\":[]}",
        day: "2026-07-20")
    check("structured digest: valid JSON normalized (date forced, keys sorted), garbage rejected",
          good == "{\"actionItems\":[],\"date\":\"2026-07-20\",\"decisions\":[{\"text\":\"ship it\"}],\"entities\":[],\"meetings\":[]}"
              && validateStructuredDigest("```json\n{\"date\":\"x\",\"meetings\":[]}\n```", day: "2026-07-20") != nil
              && validateStructuredDigest("I couldn't find any decisions.", day: "2026-07-20") == nil
              && validateStructuredDigest("[1,2,3]", day: "2026-07-20") == nil            // top-level array
              && validateStructuredDigest("{\"date\":\"x\",\"meetings\":\"oops\"}", day: "2026-07-20") == nil // wrong type
              && validateStructuredDigest("", day: "2026-07-20") == nil)
    // Review round: missing collection keys are DEFAULTED to [] (every sidecar has all four); a
    // boundary fence is stripped but a triple-backtick INSIDE a string value survives (global
    // replace once corrupted it); the promote/discard outcome is pure over (exit, reply).
    let defaulted = validateStructuredDigest("{\"date\":\"x\"}", day: "2026-07-20")
    check("structured digest: missing collections default to [] and inner backticks survive",
          defaulted == "{\"actionItems\":[],\"date\":\"2026-07-20\",\"decisions\":[],\"entities\":[],\"meetings\":[]}"
              && (validateStructuredDigest("```json\n{\"date\":\"x\",\"decisions\":[{\"text\":\"run ```make```\"}]}\n```", day: "2026-07-20")?
                  .contains("run ```make```") ?? false)
              && stripBoundaryFence("```JSON\n{\"a\":1}\n```") == "{\"a\":1}")   // case/space-tolerant boundary
    check("structured digest: promote/discard outcome is pure over (exit, reply)",
          structuredSidecarOutcome(exitStatus: 0, partial: "{\"date\":\"x\",\"meetings\":[]}", day: "2026-07-20") != nil
              && structuredSidecarOutcome(exitStatus: 1, partial: "{\"date\":\"x\"}", day: "2026-07-20") == nil   // non-zero exit
              && structuredSidecarOutcome(exitStatus: 0, partial: nil, day: "2026-07-20") == nil                 // no reply
              && structuredSidecarOutcome(exitStatus: 0, partial: "not json", day: "2026-07-20") == nil)
    // Legacy-default prompt migration: a stored prompt equal to a PAST default clears (the improved
    // default applies); a real customization is never touched.
    do {
        let d = Pref.d   // ephemeral suite under selftest
        d.set(legacyDefaultPrompts[0], forKey: Pref.summaryPrompt)
        d.set("my custom digest prompt", forKey: Pref.dailyPrompt)
        migrateLegacyDefaultPrompts(d)
        check("prompt migration: stale default cleared, customization untouched",
              d.string(forKey: Pref.summaryPrompt) == nil
                  && d.string(forKey: Pref.dailyPrompt) == "my custom digest prompt")
        d.removeObject(forKey: Pref.dailyPrompt)
    }
    // Silent-outage detection (#27): the recorder was DOWN ~18h overnight+morning and a real meeting
    // was missed with nothing shown. The forgiving clean-stop is written ONLY on a user Quit — a
    // SIGTERM/bootout death (cleanStop == nil) must still be surfaced, else the feature swallows the
    // exact incident it exists for (correctness review, P0). The pure decision must (a) flag a long gap
    // on a live mac, incl. the bootout death, (b) NOT flag an overnight shutdown (mac rebooted), (c) NOT
    // flag a deliberate Quit (clean-stop adjacent to the last beat), (d) NOT flag a quick restart /
    // first run, (e) still flag when a STALE clean-stop (from a Quit long ago) sits in prefs.
    let t0 = schedDate("2026-07-21 17:00")   // "now" on the incident's restart
    let liveMacBoot = schedDate("2026-07-16 09:00")   // mac up for days
    check("outage: an 18h bootout-death on a live mac IS surfaced (cleanStop nil — the actual incident)",
          recorderOutage(lastHeartbeat: schedDate("2026-07-20 23:00"), cleanStop: nil,
                         now: t0, bootTime: liveMacBoot).map { Int($0) } == 18 * 3600)
    check("outage: an overnight SHUTDOWN (mac rebooted during the gap) is benign, incl. the boot==last tie",
          recorderOutage(lastHeartbeat: schedDate("2026-07-20 22:00"), cleanStop: nil,
                         now: schedDate("2026-07-21 08:00"), bootTime: schedDate("2026-07-21 07:59")) == nil
              && recorderOutage(lastHeartbeat: schedDate("2026-07-20 22:00"), cleanStop: nil,
                                now: t0, bootTime: schedDate("2026-07-20 22:00")) == nil)   // bootTime == last → benign (>=)
    check("outage: a deliberate Quit (clean-stop adjacent to the last beat) is benign",
          recorderOutage(lastHeartbeat: schedDate("2026-07-20 23:00"),
                         cleanStop: schedDate("2026-07-20 23:00"), now: t0, bootTime: liveMacBoot) == nil)
    check("outage: a STALE clean-stop from an old Quit does NOT blind a later crash (last advanced past it)",
          recorderOutage(lastHeartbeat: schedDate("2026-07-20 23:00"),
                         cleanStop: schedDate("2026-07-17 09:00"),   // a Quit 3+ days before this run's last beat
                         now: t0, bootTime: liveMacBoot).map { Int($0) } == 18 * 3600)
    check("outage: a quick restart (< min gap) and a first-ever run are both benign",
          recorderOutage(lastHeartbeat: schedDate("2026-07-21 16:57"), cleanStop: nil,
                         now: t0, bootTime: liveMacBoot) == nil   // 3 min < 5-min floor
              && recorderOutage(lastHeartbeat: nil, cleanStop: nil, now: t0, bootTime: liveMacBoot) == nil)
    check("outage: humanDuration reads as h/min and the from–to window spans days when needed",
          humanDuration(18 * 3600) == "18 h" && humanDuration(45 * 60) == "45 min"
              && humanDuration(2 * 3600 + 10 * 60) == "2 h 10 min" && humanDuration(30) == "30 s"
              && outageWindowText(from: schedDate("2026-07-21 09:10"), to: schedDate("2026-07-21 09:55"), calendar: utc) == "09:10–09:55"
              && outageWindowText(from: schedDate("2026-07-20 23:00"), to: schedDate("2026-07-21 08:00"), calendar: utc) == "Jul 20 23:00–Jul 21 08:00"
              && outageMenuTitle(outageSeconds: 18 * 3600).contains("~18 h") && outageMenuTitle(outageSeconds: 0).isEmpty)
    // #36b watchdog: relaunch the recorder ONLY when it's down AND the user didn't deliberately Quit —
    // so a crash / OS memory-pressure kill / idle reap is recovered, but a menu Quit stays quit.
    check("watchdog: relaunch iff down and not deliberately quit",
          watchdogShouldRelaunch(mainRunning: false, quitRequested: false)          // died → relaunch
              && !watchdogShouldRelaunch(mainRunning: false, quitRequested: true)   // user quit → stay dead
              && !watchdogShouldRelaunch(mainRunning: true, quitRequested: false)   // up → do nothing
              && !watchdogShouldRelaunch(mainRunning: true, quitRequested: true))
    // The WIRING through the REAL beat()/noteUserQuit() — not raw d.set (test-honesty review, P0): a real
    // Quit must write a cleanStop that suppresses the next start; a bootout (no Quit) must be surfaced,
    // persisted, and shown by todayHealth + the menu line same-day only; a fresh Notifier must fire; a
    // sub-threshold gap (5–30 min) is logged but NOT surfaced.
    do {
        let d = Pref.d   // ephemeral suite under selftest
        func clear() { for k in [Pref.recorderHeartbeat, Pref.recorderCleanStop, Pref.recorderOutageAt, Pref.recorderOutageSeconds] { d.removeObject(forKey: k) } }
        clear()
        // A real Quit: beat, then noteUserQuit → cleanStop adjacent → a later start over an 18h gap is benign.
        RecorderHeartbeat.beat(now: schedDate("2026-07-20 23:00"), d: d)
        RecorderHeartbeat.noteUserQuit(now: schedDate("2026-07-20 23:00"), d: d)
        let afterQuit = RecorderHeartbeat.checkOutageOnStart(now: t0, uptime: t0.timeIntervalSince(liveMacBoot), d: d)
        // A bootout death: only a beat (no Quit) → the 18h gap IS surfaced + persisted.
        clear()
        RecorderHeartbeat.beat(now: schedDate("2026-07-20 23:00"), d: d)
        let surfaced = RecorderHeartbeat.checkOutageOnStart(now: t0, uptime: t0.timeIntervalSince(liveMacBoot), d: d)
        var hi = HealthInputs(); hi.recording = true
        hi.outageSeconds = RecorderHeartbeat.outageForToday(now: t0, d: d)
        var notified = false
        Notifier.sinkForTest = { _, _ in notified = true }
        Notifier.push(title: "macrec wasn't recording", body: "x", openWindow: "log")
        Notifier.sinkForTest = nil
        check("outage wiring: Quit suppresses, bootout surfaces+persists+notifies+shows, clears next day",
              afterQuit == nil                                   // real Quit → cleanStop → suppressed
                  && surfaced.map { Int($0) } == 18 * 3600       // bootout → surfaced
                  && Int(hi.outageSeconds) == 18 * 3600
                  && notified
                  && RecorderHeartbeat.outageForToday(now: schedDate("2026-07-23 17:00"), d: d) == 0  // +48h → later local day, clears
                  && todayHealth(hi).contains { $0.title == "Recorder was down earlier" && $0.action == .showLog }
                  && outageMenuTitle(outageSeconds: hi.outageSeconds).contains("Recorder was down"))
        // A 20-minute gap is logged (captured), never surfaced (no persistence, returns nil).
        clear()
        RecorderHeartbeat.beat(now: schedDate("2026-07-21 16:40"), d: d)   // 20 min before t0
        var logged = ""
        let sub = RecorderHeartbeat.checkOutageOnStart(now: t0, uptime: t0.timeIntervalSince(liveMacBoot), d: d,
                                                       log: { logged = $0 })
        check("outage: a 20-min gap is logged but NOT surfaced (under the alert bar)",
              sub == nil && d.double(forKey: Pref.recorderOutageSeconds) == 0 && logged.contains("20 min"))
        clear()
        // The tray menu line is actually WIRED (dead-affordance lesson): with a same-day outage in prefs
        // the real menu open leaves it titled, un-hidden and clickable; with nothing, it stays hidden.
        // refreshPostProcessRows reads outageForToday() at the REAL now, so stamp "today" as real now.
        d.set(Date().timeIntervalSince1970, forKey: Pref.recorderOutageAt)
        d.set(Double(18 * 3600), forKey: Pref.recorderOutageSeconds)
        let shown = AppController().outageMenuLineAfterMenuOpenForTest()
        clear()
        let gone = AppController().outageMenuLineAfterMenuOpenForTest()
        check("outage: the tray menu line is wired — shown+clickable with a same-day outage, hidden without",
              shown != nil && shown!.title.contains("Recorder was down") && shown!.hidden == false && shown!.enabled
                  && gone != nil && gone!.hidden == true)
    }
    // Orphan-segment adoption: stem parsing, pairing, the fresh-file veto, and the file-scan
    // stats matching the live writer (same rules by construction — streamed through SourceWriter).
    check("adopt: stem dates parse, stems pair, one fresh file vetoes the stem",
          orphanSegmentStart("seg-2026-03-05-100000") != nil
              && orphanSegmentStart("seg-garbage") == nil && orphanSegmentStart("notes") == nil
              && orphanSegmentStems(names: ["seg-2026-03-05-100000.mic.wav", "seg-2026-03-05-100000.sys.wav",
                                            "stray.wav", "seg-2026-03-05-110000.mic.wav"],
                                    modified: { _ in Date(timeIntervalSinceNow: -600) }, now: Date())
              == ["seg-2026-03-05-100000", "seg-2026-03-05-110000"]
              && orphanSegmentStems(names: ["seg-2026-03-05-100000.mic.wav", "seg-2026-03-05-100000.sys.wav"],
                                    modified: { $0.hasSuffix(".sys.wav") ? Date() : Date(timeIntervalSinceNow: -600) },
                                    now: Date()).isEmpty)
    do {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("mr-scan-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("sig.wav")
        var expect: (voiced: Double, speech: Double, peak: Float) = (0, 0, 0)
        if let w = try? SourceWriter(url: wav),
           let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
           let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 8000) {
            buf.frameLength = 8000
            for rep in 0..<6 {
                for i in 0..<8000 { buf.floatChannelData![0][i] = i < 6400 ? sinf(Float(rep * 8000 + i) * 0.13) * 0.3 : 0 }
                w.append(buf)
            }
            expect = (w.voicedSeconds, w.speechSeconds, w.peak)
        }
        let got = scanWavStats(wav, scratchDir: dir)
        check("adopt: file-scan stats match the live writer's",
              got != nil && abs((got?.voiced ?? -1) - expect.voiced) < 0.02
                  && abs((got?.speech ?? -1) - expect.speech) < 0.02
                  && abs((got?.peak ?? -1) - expect.peak) < 0.001
                  && (got?.duration ?? 0) > 2.5)   // the converter buffers a tail; scan sees what the file holds
        try? fm.removeItem(at: dir)
    }
    // Title extraction for untitled recordings — every layer around the one runner call is pure.
    check("title: untitled-stem detection",
          isUntitledStem("2026-03-01-1600")
              && !isUntitledStem("2026-03-01-1600-project-kickoff")
              && !isUntitledStem("2026-03-01")
              && !isUntitledStem("notes-2026-03-01-1600"))
    check("title: runner replies clean into usable titles, garbage stays nil",
          cleanExtractedTitle("\"프로젝트 킥오프.\"") == "프로젝트 킥오프"
              && cleanExtractedTitle("\n\n  Weekly sync notes  \nBecause you asked…") == "Weekly sync notes"
              // Truncate at a word boundary under 48; topic prompt; strip promoted punctuation.
              && cleanExtractedTitle("Quarterly planning review and cross team roadmap alignment session for the platform group") == "Quarterly planning review and cross team roadmap"
              && cleanExtractedTitle(String(repeating: "가", count: 60)) == nil   // an unbroken 48+ token is noise
              && cleanExtractedTitle("Quarterly planning review and cross team. roadmap alignment session") == "Quarterly planning review and cross team"
              && titleExtractionInvocation(runner: .claude, summaryPath: "/tmp/x.md").contains("topic or activity")
              && cleanExtractedTitle("# Title!") == "Title"
              && cleanExtractedTitle("") == nil
              && cleanExtractedTitle("!!! …") == nil
              && cleanExtractedTitle("NONE") == nil // the no-content protocol (live: an empty flush got named)
              && cleanExtractedTitle("\"none.\"") == nil
              && cleanExtractedTitle(String(repeating: "x", count: 200)) == nil
              && titleExtractionInvocation(runner: .claude, summaryPath: "/s.md").contains("NONE"))
    do {
        let files = ["/t/2026-03/2026-03-01-1600.md", "/s/2026-03/2026-03-01-1600-sum.md",
                     "/a/2026-03/2026-03-01-1600.wav"]
        let plan = titleRenamePlan(files: files, stem: "2026-03-01-1600", slug: "kickoff",
                                   exists: { files.contains($0) })
        check("title: rename plan covers the set, keeps the -sum suffix, refuses anything unsafe",
              plan?.count == 3
                  && plan?.contains { $0.to == "/s/2026-03/2026-03-01-1600-kickoff-sum.md" } == true
                  && plan?.contains { $0.to == "/t/2026-03/2026-03-01-1600-kickoff.md" } == true
                  && titleRenamePlan(files: files, stem: "2026-03-01-1600", slug: "kickoff",
                                     exists: { files.contains($0) || $0.hasSuffix("-kickoff.md") }) == nil // collision
                  && titleRenamePlan(files: ["/x/other.md"], stem: "2026-03-01-1600", slug: "k",
                                     exists: { _ in true }) == nil                                          // non-sibling
                  && titleRenamePlan(files: files, stem: "2026-03-01-1600-titled", slug: "k",
                                     exists: { _ in true }) == nil)                                         // already titled
    }
    // The apply step, end to end on a real (temp) tree: renames + audio-link + summary-H1 fixups.
    do {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mr-title-\(UUID().uuidString)")
        let t = root.appendingPathComponent("t/2026-03")
        let s = root.appendingPathComponent("s/2026-03")
        let a = root.appendingPathComponent("a/2026-03")
        for d in [t, s, a] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let tp = t.appendingPathComponent("2026-03-01-1600.md").path
        try? "# 2026-03-01 16:00\n- Audio: [2026-03-01-1600.wav](../../a/2026-03/2026-03-01-1600.wav)\nbody"
            .write(toFile: tp, atomically: true, encoding: .utf8)
        let sp = s.appendingPathComponent("2026-03-01-1600.md").path
        try? "# 2026-03-01-1600\n\nsummary body".write(toFile: sp, atomically: true, encoding: .utf8)
        fm.createFile(atPath: a.appendingPathComponent("2026-03-01-1600.wav").path, contents: Data("x".utf8))
        let r = applyExtractedTitle(transcriptPath: tp, summaryPath: sp,
                                    audioDir: root.appendingPathComponent("a").path, title: "Project Kickoff")
        let newT = (try? String(contentsOfFile: r?.transcript ?? "", encoding: .utf8)) ?? ""
        let newS = (try? String(contentsOfFile: r?.summary ?? "", encoding: .utf8)) ?? ""
        check("title: apply renames the set and rewrites the audio link + summary H1",
              r?.transcript.hasSuffix("2026-03-01-1600-Project-Kickoff.md") == true
                  && fm.fileExists(atPath: a.appendingPathComponent("2026-03-01-1600-Project-Kickoff.wav").path)
                  && !fm.fileExists(atPath: tp)
                  && newT.contains("2026-03-01-1600-Project-Kickoff.wav")
                  && !newT.contains("2026-03-01-1600.wav")
                  && newS.hasPrefix("# 2026-03-01-1600-Project-Kickoff"))
        check("title: a titled recording is never re-renamed",
              applyExtractedTitle(transcriptPath: r?.transcript ?? "", summaryPath: r?.summary,
                                  audioDir: root.appendingPathComponent("a").path, title: "Again") == nil)
        try? fm.removeItem(at: root)
    }
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
    // Digest files get the same file-name H1 as summaries, composed only after the runner succeeds
    // (see titledPromoteTail — the .partial must keep the runner's own words on failure).
    let digCmd = dailyDigestInvocation(runner: .claude, prompt: "P", inputs: ["/s/a.md", "/s/b's.md"],
                                       outPath: "/d/2026-07/x.md") ?? ""
    check("digest: invocation cats inputs into the runner; H1 = file name; promote on success",
          digCmd.hasPrefix("mkdir -p '/d/2026-07' && cat '/s/a.md' '/s/b'\\''s.md' | claude --safe-mode -p 'P' > '/d/2026-07/x.md.partial'")
          && digCmd.contains("&& { printf '# %s\\n\\n' 'x'; cat '/d/2026-07/x.md.partial'; }")
          && digCmd.contains("&& mv '/d/2026-07/x.md.partial2' '/d/2026-07/x.md'")
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
    check("naming: calendar-first stamps — the event's start for its first slice, clamped after",
          transcriptStart(segStart: segA, segEnd: segAEnd, eventStart: nil) == segA
          && transcriptStart(segStart: segA, segEnd: segAEnd,
                             eventStart: schedDate("2026-07-05 21:10")) == schedDate("2026-07-05 21:10")
          // Calendar-first: a late-joining recording still files under the meeting's own start.
          && transcriptStart(segStart: segA, segEnd: segAEnd,
                             eventStart: schedDate("2026-07-05 20:30")) == schedDate("2026-07-05 20:30")
          && transcriptStart(segStart: segA, segEnd: segAEnd,
                             eventStart: schedDate("2026-07-05 20:30"), eventTaken: true) == segA
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
                               now: schedDate("2026-07-08 10:00"), padding: 60)               // zero-duration event ignored
          && !meetingActiveNow(mtg, now: schedDate("2026-07-08 09:30"), padding: .infinity)   // +inf clamped → not all-time
          && meetingActiveNow(mtg, now: schedDate("2026-07-08 10:30"), padding: .nan))         // NaN clamped to 0 → mid-meeting active
    check("calendar pad seconds: clamped [0, 24h], overflow-safe on a huge pref value",
          calendarPadSeconds(5) == 300 && calendarPadSeconds(-5) == 0
          && calendarPadSeconds(1440) == 86400 && calendarPadSeconds(1441) == 86400
          && calendarPadSeconds(Int.max) == 86400)   // Int.max must clamp, never trap on Int × 60
    check("recording window: each gate blocks independently; both-off admits all",
          recordingWindowActive(scheduleEnabled: false, scheduleActive: false, calendarGated: false, meetingActive: false)   // both off → yes
          && recordingWindowActive(scheduleEnabled: true, scheduleActive: true, calendarGated: true, meetingActive: true)    // both pass → yes
          && !recordingWindowActive(scheduleEnabled: true, scheduleActive: false, calendarGated: true, meetingActive: true)  // schedule blocks (calendar passes)
          && !recordingWindowActive(scheduleEnabled: true, scheduleActive: true, calendarGated: true, meetingActive: false)  // calendar blocks (schedule passes)
          && !recordingWindowActive(scheduleEnabled: false, scheduleActive: false, calendarGated: true, meetingActive: false) // schedule OFF, calendar blocks
          && !recordingWindowActive(scheduleEnabled: true, scheduleActive: false, calendarGated: false, meetingActive: false) // calendar OFF, schedule blocks
          && recordingWindowActive(scheduleEnabled: true, scheduleActive: true, calendarGated: false, meetingActive: false)  // calendar off → schedule only
          && recordingWindowActive(scheduleEnabled: false, scheduleActive: false, calendarGated: true, meetingActive: true)) // schedule off → calendar only
    check("recording window state: fail-open on missing permission; schedule is the outer reason",
          recordingWindowState(scheduleEnabled: false, scheduleActive: false, calendarGated: false,
                               calendarAuthorized: false, meetingActive: false) == nil                     // nothing gates → record
          && recordingWindowState(scheduleEnabled: true, scheduleActive: false, calendarGated: false,
                                  calendarAuthorized: true, meetingActive: false) == .offHours             // schedule blocks
          && recordingWindowState(scheduleEnabled: false, scheduleActive: false, calendarGated: true,
                                  calendarAuthorized: true, meetingActive: false) == .noMeeting            // calendar blocks
          && recordingWindowState(scheduleEnabled: true, scheduleActive: false, calendarGated: true,
                                  calendarAuthorized: true, meetingActive: false) == .offHours             // BOTH gates block → schedule (outer) reason
          && recordingWindowState(scheduleEnabled: false, scheduleActive: false, calendarGated: true,
                                  calendarAuthorized: false, meetingActive: false) == nil                  // GATED but no permission → fail OPEN
          && recordingWindowState(scheduleEnabled: false, scheduleActive: false, calendarGated: true,
                                  calendarAuthorized: true, meetingActive: true) == nil)                   // in a meeting → record
    check("override expiry: no schedule boundary holds forever (distantFuture), else the schedule boundary",
          overrideExpiry(RecordSchedule(enabled: false, weekdays: [], ranges: []),
                         now: schedDate("2026-07-08 10:30")) == .distantFuture                             // calendar-only: Resume must hold
          && overrideExpiry(RecordSchedule.from(enabled: true, days: "mon-fri", hours: "10:00-19:00"),
                            now: schedDate("2026-07-08 10:30")) != .distantFuture)                         // real schedule DOES flip
    // Speech-run accounting — MUST be fed oscillating audio, not DC steps. The 2026-07-15 incident:
    // the old per-sample run metric was pinned green with Array(repeating: 0.5, …) fixtures, which
    // never cross zero — real audio does every half-cycle, so the metric scored every real recording
    // 0 s (a real meeting's longest sample run: 83 samples = 5 ms) and every uncalendared call was
    // discarded by the no-meeting gate. The envelope metric must pass a sine where samples fail.
    let sine: (Int) -> [Float] = { n in (0..<n).map { sinf(Float($0) * 0.13) * 0.3 } }   // ~331 Hz, amp 0.3
    check("mic guard: envelope speech-run accounting (sine qualifies, clicks and blips never)",
          speechlikeFrames(sine(16000)) == 15872                                  // 1 s sine = 62 full blocks, all speech
          && speechlikeFrames(sine(15 * 256) + [Float](repeating: 0, count: 256)) == 0   // 240 ms — just under the run bar
          && speechlikeFrames(sine(16 * 256)) == 16 * 256                          // 256 ms — qualifies exactly
          && speechlikeFrames((0..<80000).map { $0 % 3200 == 0 ? 0.9 : 0.0 }) == 0 // isolated pops (jack incident)
          && speechlikeFrames((0..<16000).map { sinf(Float($0) * 0.13) * 0.01 }) == 0   // below the energy floor
          && speechlikeFrames(sine(6400) + [Float](repeating: 0, count: 1600) + sine(6400)) == 12800)  // two utterances
    // DENSE click train — 8 hot samples in every 100: its block RMS clears the energy bar, so the
    // review round proved RMS-only scoring would count 99% of it as speech. The ≥¼-of-samples duty
    // floor is what rejects it (voiced speech keeps ≥ half its samples above the floor). And a
    // corrupt sample must poison nothing in either direction: a NaN inside real speech keeps the
    // block voiced; a stray Inf in silence must not fabricate one.
    var nanSpeech = sine(16 * 256); nanSpeech[100] = .nan
    var infSilence = [Float](repeating: 0, count: 16 * 256)
    for i in stride(from: 0, to: infSilence.count, by: 256) { infSilence[i] = .infinity }
    check("mic guard: dense click trains, NaN and Inf never score as speech",
          speechlikeFrames((0..<8000).map { $0 % 100 < 8 ? 0.5 : 0.0 }) == 0
          && speechlikeFrames(nanSpeech) == 16 * 256
          && speechlikeFrames(infSilence) == 0)
    check("mic guard: dead-input verdict (energy without speech runs)",
          micLooksDead(voiced: 44.1, speech: 0.1)       // the real incident segment
          && micLooksDead(voiced: 14.7, speech: 0.0)    // 2026-07-15 22:00 — clicks, caught live
          && !micLooksDead(voiced: 22.4, speech: 8.0)   // real speech
          && !micLooksDead(voiced: 52.1, speech: 35.2)  // 2026-07-15 standup — the metric bug made this warn
          && !micLooksDead(voiced: 3.0, speech: 0.0)    // quiet hour — no verdict
          && !micLooksDead(voiced: 8.0, speech: 0.0)    // backchannel-only hour (short utterances) — no cry-wolf
          && !micLooksDead(voiced: 6.0, speech: 0.6))   // borderline but speech present
    // Captured-silence (dropped-metric): MIC peak only — the system tap is exactly 0 whenever no
    // app plays, so it can never separate dead from idle. A live mic's noise floor clears epsilon.
    check("capture silence: zero mic is silence; a noise floor or a voice is not; streak needs 2",
          isCaptureSilent(micPeak: 0.0) && isCaptureSilent(micPeak: 0.0005)
              && !isCaptureSilent(micPeak: 0.005) && !isCaptureSilent(micPeak: 0.3)
              && !capturedSilenceRun(silentStreak: 1) && capturedSilenceRun(silentStreak: 2))
    // Eligibility: ONLY a live, permitted rotation counts — locked/unpermitted/manual/adopted
    // segments are silent by design and once cried wolf (review P0s on the first cut).
    check("capture silence: eligibility excludes suspended, unpermitted, manual, and adopted",
          captureSilenceEligible(micGranted: true, suspended: false, manual: false, adopted: false)
              && !captureSilenceEligible(micGranted: false, suspended: false, manual: false, adopted: false)
              && !captureSilenceEligible(micGranted: true, suspended: true, manual: false, adopted: false)
              && !captureSilenceEligible(micGranted: true, suspended: false, manual: true, adopted: false)
              && !captureSilenceEligible(micGranted: true, suspended: false, manual: false, adopted: true))
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
