import Foundation

// Today dashboard — the pure health verdicts, each pinned to the real incident it guards.
func todaySelftests(_ check: (String, Bool) -> Void) {
    // A healthy baseline: recording, all granted, model ready, runner idle, digest due later.
    var ok = HealthInputs()
    ok.audioGranted = true; ok.micGranted = true; ok.calendarGranted = true
    ok.recording = true; ok.micLevel = 0.4; ok.sysLevel = 0.3
    ok.modelReady = true; ok.modelName = "large-v3"; ok.whisperResolved = true
    ok.runnerResolved = true; ok.runnerName = "claude"; ok.summary = .idle
    ok.digestEnabled = true; ok.digestTime = "20:00"
    ok.now = dateAt(hour: 10, minute: 0)

    let okRows = todayHealth(ok)
    check("today: a healthy pipeline reports all-ok",
          okRows.allSatisfy { $0.level == .ok } && overallHealth(okRows).level == .ok
              && overallHealth(okRows).line.contains("healthy"))

    // The muted-tap P0 (#132): only the CONFIRMED capture test flags it BAD — never a passive
    // guess. Core Audio tracks ~48 audio processes at all times, so "is anything playing?" can't
    // be read cheaply; a quiet room must never read as broken (the documented cry-wolf trap).
    var muted = ok; muted.captureTest = .silent
    let mutedRows = todayHealth(muted)
    let capture = mutedRows.first { $0.group == "Capture" }
    check("today: a confirmed-silent capture test is BAD with a re-test action",
          capture?.level == .bad && capture?.action == .testCapture
              && overallHealth(mutedRows).level == .bad)
    // Untested (the passive default) and a quiet room are both fine — no cry-wolf.
    check("today: untested capture in a quiet room is not flagged",
          todayHealth(ok).first { $0.group == "Capture" }?.level == .ok
              && todayHealth(ok).first { $0.group == "Capture" }?.action == .testCapture)
    var verified = ok; verified.captureTest = .captured
    check("today: a passed capture test reads 'verified' and stays ok",
          todayHealth(verified).first { $0.group == "Capture" }?.detail.contains("verified") == true
              && todayHealth(verified).first { $0.group == "Capture" }?.level == .ok)

    // Permissions: audio/mic denial is fatal (bad + Grant); calendar denial is only a warning.
    var noPerm = ok; noPerm.audioGranted = false; noPerm.calendarGranted = false
    let permRows = todayHealth(noPerm).filter { $0.group == "Permissions" }
    check("today: audio denial is fatal, calendar denial is a warning, both offer Grant",
          permRows.first { $0.title == "System Audio Recording" }?.level == .bad
              && permRows.first { $0.title == "System Audio Recording" }?.action == .grantPermissions
              && permRows.first { $0.title == "Calendar" }?.level == .warn
              && overallHealth(todayHealth(noPerm)).level == .bad)

    // Model: downloading is a warning, absent is bad with an Open-Settings action.
    var dl = ok; dl.modelReady = false; dl.modelDownloading = true
    var absent = ok; absent.modelReady = false; absent.modelDownloading = false
    check("today: model downloading=warn, absent=bad+settings",
          todayHealth(dl).first { $0.title == "Model" }?.level == .warn
              && todayHealth(absent).first { $0.title == "Model" }?.level == .bad
              && todayHealth(absent).first { $0.title == "Model" }?.action == .openSettings(pane: "Model"))

    // Summary FAILED surfaces the runner's own reason + a Retry (the silent-post-process incident).
    var failed = ok
    failed.summary = .failed("2026-07-19-1400.md", dateAt(hour: 14, minute: 5), reason: "Not logged in")
    let fRow = todayHealth(failed).first { $0.title == "Summary FAILED" }
    check("today: a failed summary shows the reason and a Retry",
          fRow?.level == .bad && fRow?.detail.contains("Not logged in") == true && fRow?.action == .retrySummary)

    // A runner that isn't on PATH is bad even while idle.
    var noRunner = ok; noRunner.runnerResolved = false
    check("today: an unresolvable summary runner is bad",
          todayHealth(noRunner).first { $0.title == "Summary runner" }?.level == .bad)

    // Digest overdue: past the time and not run → warn; ran today → ok regardless of time.
    var overdue = ok; overdue.now = dateAt(hour: 22, minute: 0); overdue.digestRanToday = false
    var ranAlready = overdue; ranAlready.digestRanToday = true
    check("today: digest overdue after its time, ok once it ran",
          todayHealth(overdue).first { $0.title == "Daily digest" }?.level == .warn
              && todayHealth(ranAlready).first { $0.title == "Daily digest" }?.level == .ok
              && !digestOverdue(now: dateAt(hour: 10, minute: 0), time: "20:00", ranToday: false)
              && digestOverdue(now: dateAt(hour: 20, minute: 0), time: "20:00", ranToday: false)
              && !digestOverdue(now: dateAt(hour: 22, minute: 0), time: "25:99", ranToday: false))

    // The overall line always names the worst row, so the tray and the dashboard can't disagree.
    check("today: overall verdict names the worst row",
          overallHealth(todayHealth(muted)).line.contains("silent")
              && overallHealth(todayHealth(overdue)).level == .warn)

    // Output counts read file NAMES only. THE default config: summaries live side-by-side as
    // "-sum" in the SAME tree, so the sampler passes one identical listing for both — a summary
    // must be the "-sum" file, never every transcript (the incident: "5 transcripts, 10 summarized").
    // The bare-date daily-digest stem must count as neither.
    let shared = ["2026-07-19-1030-standup", "2026-07-19-1030-standup-sum",
                  "2026-07-19-1400", "2026-07-18-0900-old", "2026-07-19", "stray"]
    let beside = todayOutputCounts(transcriptStems: shared, summaryStems: shared,
                                   day: "2026-07-19", summariesSideBySide: true)
    check("today: side-by-side counts — transcripts exclude -sum & digest, summaries are only -sum",
          beside.transcripts == 2 && beside.summaries == 1)
    // A dedicated summary dir: summaries are plain <stem>.md there.
    let dedicated = todayOutputCounts(transcriptStems: ["2026-07-19-1030-standup", "2026-07-19-1400"],
                                      summaryStems: ["2026-07-19-1030-standup"],
                                      day: "2026-07-19", summariesSideBySide: false)
    check("today: dedicated-dir counts and other-day exclusion",
          dedicated == (2, 1)
              && todayOutputCounts(transcriptStems: shared, summaryStems: shared,
                                   day: "2026-07-17", summariesSideBySide: true) == (0, 0))

    // The dashboard drives the real view: rows render, layout is clean at BOTH the default and the
    // minimum window size, and each HealthAction maps to the RIGHT button (window wiring). One
    // input that exercises Test / Grant / Retry / no-button together.
    var mix = ok; mix.captureTest = .silent; mix.calendarGranted = false
    mix.summary = .failed("x.md", dateAt(hour: 14, minute: 0), reason: "Not logged in")
    mix.outageSeconds = 18 * 3600   // #27: a past outage row must render an "Open log" button, not a dead end
    mix.notificationsDenied = true  // #33: a "Notifications off" row must render a Settings… deep-link
    let tw = TodayWindow.shared
    tw.loadFixtureForTest(todayHealth(mix))
    let issues = tw.layoutIssues() + tw.layoutIssuesAtMinSize()
    check("today: window renders rows cleanly at default and min size, maps actions to buttons",
          issues.isEmpty
              && tw.actionButtonTitleForTest(rowTitle: "System audio is silent") == "Test…"
              && tw.actionButtonTitleForTest(rowTitle: "Calendar") == "Grant…"
              && tw.actionButtonTitleForTest(rowTitle: "Summary FAILED") == "Retry"
              && tw.actionButtonTitleForTest(rowTitle: "Recorder was down earlier") == "Open log"   // not a dead affordance
              && tw.actionButtonTitleForTest(rowTitle: "Notifications") == "Settings…"              // #33 deep-link
              && tw.actionButtonTitleForTest(rowTitle: "Microphone") == nil)   // granted → no button
    // #33: the row shows ONLY on definitive denial (not undetermined), is a warn, and never background-alerts.
    check("today: notifications-off is a warn row, only when denied, and never a background alert",
          todayHealth({ var i = ok; i.notificationsDenied = true; return i }()).contains {
              $0.title == "Notifications" && $0.level == .warn && $0.suppressBackgroundAlert
          }
              && !todayHealth(ok).contains { $0.title == "Notifications" })   // default (not denied) → no row
    for i in issues { elog("selftest: \(i)") }

    // #32: a closed window still warns — BAD conditions become notifications, DEBOUNCED (bad on two
    // consecutive samples) so a one-tick transient (an engine restart on schedule/calendar resume) never
    // alerts; deduped so a persistent one alerts once; a cleared condition can recur; rows that
    // self-surface (permissions via the OS prompt, Summary FAILED via the pipeline) never alert.
    let notRec = HealthRow(group: "Capture", title: "Not recording", detail: "The engine isn't capturing.", level: .bad, action: .none)
    let toolBad = HealthRow(group: "Pipeline", title: "whisper-cli", detail: "Not found on PATH.", level: .bad, action: .openSettings(pane: "Transcripts"))
    let micBad = HealthRow(group: "Permissions", title: "Microphone", detail: "Denied.", level: .bad, action: .grantPermissions, suppressBackgroundAlert: true)
    let sumFail = HealthRow(group: "Pipeline", title: "Summary FAILED", detail: "x — boom", level: .bad, action: .retrySummary, suppressBackgroundAlert: true)
    let paused = HealthRow(group: "Capture", title: "Paused", detail: "Recording is paused.", level: .warn, action: .none)
    let all = [notRec, toolBad, micBad, sumFail, paused]
    let (t1, bad1, al1) = healthAlerts(rows: all, lastBad: [], alerted: [])              // first sight: debounce holds
    let (t2, bad2, al2) = healthAlerts(rows: all, lastBad: bad1, alerted: al1)           // 2nd consecutive: confirm+alert
    let (t3, bad3, al3) = healthAlerts(rows: [notRec, toolBad], lastBad: bad2, alerted: al2)   // persistent: no repeat
    let (t4, bad4, al4) = healthAlerts(rows: [toolBad], lastBad: bad3, alerted: al3)     // notRec clears → drops
    let (t5, bad5, al5) = healthAlerts(rows: [notRec, toolBad], lastBad: bad4, alerted: al4)   // notRec recurs (1 tick)
    let (t6, _, _) = healthAlerts(rows: [notRec, toolBad], lastBad: bad5, alerted: al5)  // 2nd tick → re-alert
    check("health alerts: debounced (2 ticks), deduped, clear-then-recur, suppressed rows never alert",
          t1.isEmpty                                                     // one sample only → nothing yet
              && bad1 == ["Capture/Not recording", "Pipeline/whisper-cli"]   // mic + sumFail suppressed, paused warn
              && Set(t2.map(\.title)) == ["Not recording", "whisper-cli"]    // confirmed on 2nd tick
              && t3.isEmpty                                              // persistent → no repeat
              && al4 == ["Pipeline/whisper-cli"]                        // cleared notRec drops from alerted
              && t5.isEmpty                                             // recurrence needs 2 ticks again
              && t6.map(\.title) == ["Not recording"])                  // re-alerts after 2 consecutive
    // P0 regression (review): a ONE-tick transient — engine==nil for a single tick during a legitimate
    // schedule/calendar resume — must NEVER alert, because it clears before the debounce confirms it.
    let (x1, xbad1, xal1) = healthAlerts(rows: [notRec], lastBad: [], alerted: [])   // tick: transient bad
    let (x2, _, _) = healthAlerts(rows: [], lastBad: xbad1, alerted: xal1)           // next tick: gone
    check("health alerts: a one-tick transient (engine restarting) never alerts", x1.isEmpty && x2.isEmpty)
    // The Grant button must lead SOMEWHERE for every missing grant (the OS won't re-prompt a denial):
    // audio (fatal) wins, else mic, and mic-only-denied must NOT dead-end at no pane.
    check("permissions: deep-link pane picks the missing grant (audio first, then mic), nil when both ok",
          permissionDeepLinkPane(audioOK: false, micOK: true) == "Privacy_AudioCapture"
              && permissionDeepLinkPane(audioOK: true, micOK: false) == "Privacy_Microphone"   // was a dead end
              && permissionDeepLinkPane(audioOK: false, micOK: false) == "Privacy_AudioCapture"
              && permissionDeepLinkPane(audioOK: true, micOK: true) == nil)
    // The tray menu's health line (the menu-bar user's surface for a BROKEN pipeline): the worst BAD
    // condition by name, a count when several, "" (hidden) when nothing is broken.
    let mRec = HealthRow(group: "Capture", title: "Not recording", detail: "x", level: .bad, action: .none)
    let mTool = HealthRow(group: "Pipeline", title: "whisper-cli", detail: "x", level: .bad, action: .none)
    let mWarn = HealthRow(group: "Capture", title: "Paused", detail: "x", level: .warn, action: .none)
    let mOK = HealthRow(group: "Today", title: "Transcribed", detail: "x", level: .ok, action: .none)
    check("menu health line: worst bad by name, count when several, empty when healthy",
          menuHealthLine([mRec, mTool, mWarn]) == "⚠︎ Not recording (+1 more)"
              && menuHealthLine([mTool, mWarn]) == "⚠︎ whisper-cli"
              && menuHealthLine([mWarn, mOK]).isEmpty        // warns don't trip the menu line
              && menuHealthLine([mOK]).isEmpty)
    // WIRED (dead-affordance lesson): the real menu open sets the line from live health (no engine in
    // the selftest → "Not recording") and it's clickable → Today; consistency: hidden iff empty.
    if let m = AppController().healthMenuLineAfterMenuOpenForTest() {
        check("menu health line: real menu shows it when broken, clickable → Today, hidden⇔empty",
              !m.title.isEmpty && !m.hidden && m.opensToday && (m.hidden == m.title.isEmpty))
    } else {
        check("menu health line: the menu built for the wiring check", false)
    }
}

private func dateAt(hour: Int, minute: Int) -> Date {
    var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 19; c.hour = hour; c.minute = minute
    return Calendar.current.date(from: c)!
}
