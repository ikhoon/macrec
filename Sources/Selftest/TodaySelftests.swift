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
    let tw = TodayWindow.shared
    tw.loadFixtureForTest(todayHealth(mix))
    let issues = tw.layoutIssues() + tw.layoutIssuesAtMinSize()
    check("today: window renders rows cleanly at default and min size, maps actions to buttons",
          issues.isEmpty
              && tw.actionButtonTitleForTest(rowTitle: "System audio is silent") == "Test…"
              && tw.actionButtonTitleForTest(rowTitle: "Calendar") == "Grant…"
              && tw.actionButtonTitleForTest(rowTitle: "Summary FAILED") == "Retry"
              && tw.actionButtonTitleForTest(rowTitle: "Recorder was down earlier") == "Open log"   // not a dead affordance
              && tw.actionButtonTitleForTest(rowTitle: "Microphone") == nil)   // granted → no button
    for i in issues { elog("selftest: \(i)") }
}

private func dateAt(hour: Int, minute: Int) -> Date {
    var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 19; c.hour = hour; c.minute = minute
    return Calendar.current.date(from: c)!
}
