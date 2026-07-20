import Foundation

// MARK: - the Today dashboard's pure core (see DESIGN-today.md)

// macrec's recurring failure is the SILENT one — a muted tap, a metric that scored all audio 0 s,
// a discarded segment — invisible until a human noticed hours later. todayHealth() turns each
// class into a visible verdict. It is PURE: everything sampled from the world arrives in
// HealthInputs, so the whole panel is selftestable without a GUI, audio, or the network. The view
// is a dumb renderer of the returned rows.

/// Everything the dashboard needs, sampled from the world and injected (never read inside).
struct HealthInputs {
    var audioGranted = false
    var micGranted = false
    var calendarGranted = false
    var recording = false
    var paused = false
    var micLevel: Float = 0 // 0…1 live input meter
    var sysLevel: Float = 0
    // Passively we CANNOT tell a quiet room from a muted tap (Core Audio tracks ~48 audio
    // processes at all times, so "is anything playing?" can't be read cheaply). The definitive
    // muted-tap check is the Test… button, which runs the real tap-probe; its verdict lands here.
    var captureTest: CaptureTest = .untested
    var modelReady = false
    var modelName = ""
    var modelDownloading = false
    var whisperResolved = false
    var runnerResolved = false
    var runnerName = ""
    var summary: SummaryActivity = .off
    var transcriptsToday = 0
    var summariesToday = 0
    var digestEnabled = false
    var digestTime = "20:00"
    var digestRanToday = false
    // A silent outage detected on this run's start (the recorder was dead for a stretch while the mac
    // was awake) — seconds, or 0 when there's nothing to report. Surfaced so a past gap isn't invisible.
    var outageSeconds: Double = 0
    // macOS notification authorization is DEFINITIVELY denied (not merely undetermined). When it is, the
    // outage/health push alerts silently never arrive — the user must be told in-app, or they trust a
    // safety net that isn't there. Default false (assume ok until the async query says otherwise).
    var notificationsDenied = false
    var now = Date()
}

enum HealthLevel: Int, Comparable {
    case ok, warn, bad
    static func < (l: HealthLevel, r: HealthLevel) -> Bool { l.rawValue < r.rawValue }
}

/// The result of the on-demand capture test (the Test… button running tap-probe). Passive sampling
/// can't produce `.silent` — only the real test can, so a quiet room never reads as broken.
enum CaptureTest: Equatable { case untested, captured, silent }

/// What a red/amber row lets the user DO — a control that is shown must act (codebase rule).
enum HealthAction: Equatable {
    case none
    case grantPermissions
    case openSettings(pane: String)
    case retrySummary
    case testCapture
    case showLog                    // open the app log (where the #27 "was DOWN" detail lives)
    case openNotificationSettings   // System Settings > Notifications (alerts are off)
}

struct HealthRow: Equatable {
    let group: String
    let title: String
    let detail: String
    let level: HealthLevel
    let action: HealthAction
    // #32: this condition already has its OWN proactive surface (the pipeline's failure notification;
    // the OS permission prompt + tray Grant item), so the closed-window health alert must NOT also push
    // it — else it double-signals. Data-driven so a new self-surfacing row opts out at construction.
    var suppressBackgroundAlert = false
}

/// The whole panel, derived purely. Rows are grouped Capture / Permissions / Pipeline / Today.
/// Every verdict here is pinned by a selftest reproducing the real incident it guards.
func todayHealth(_ i: HealthInputs) -> [HealthRow] {
    var rows: [HealthRow] = []

    // ---- Capture ----
    if i.paused {
        rows.append(HealthRow(group: "Capture", title: "Paused", detail: "Recording is paused.",
                              level: .warn, action: .none))
    } else if !i.recording {
        rows.append(HealthRow(group: "Capture", title: "Not recording",
                              detail: "The engine isn't capturing.", level: .bad, action: .none))
    } else if i.captureTest == .silent {
        // The muted-tap P0 (#132), CONFIRMED by the on-demand test — not a passive guess.
        rows.append(HealthRow(group: "Capture", title: "System audio is silent",
                              detail: "The capture test played a tone but the tap heard nothing — check output routing.",
                              level: .bad, action: .testCapture))
    } else {
        let tested = i.captureTest == .captured ? " · capture verified" : ""
        rows.append(HealthRow(group: "Capture", title: "Recording",
                              detail: String(format: "mic %.0f%% · system %.0f%%%@", i.micLevel * 100, i.sysLevel * 100, tested),
                              level: .ok, action: .testCapture))
    }
    // A past outage detected today — recording is fine NOW, but a gap earlier was invisible until this
    // row (#27). Warn, not bad: the current state is healthy; this is a heads-up that a window was missed.
    if i.outageSeconds > 0 {
        rows.append(HealthRow(group: "Capture", title: "Recorder was down earlier",
                              detail: "No recording for ~\(humanDuration(i.outageSeconds)) today — a meeting in that window may not have been captured. Open the log for details.",
                              level: .warn, action: .showLog))
    }

    // ---- Permissions ----
    for (name, granted) in [("System Audio Recording", i.audioGranted),
                            ("Microphone", i.micGranted),
                            ("Calendar", i.calendarGranted)] {
        // Calendar is optional (titles only) — its absence is a warning, the audio ones are fatal.
        let fatal = name != "Calendar"
        rows.append(HealthRow(group: "Permissions", title: name,
                              detail: granted ? "Granted." : (fatal ? "Denied — capture can't work." : "Denied — transcripts won't get calendar titles."),
                              level: granted ? .ok : (fatal ? .bad : .warn),
                              action: granted ? .none : .grantPermissions,
                              // The OS prompt fires the moment a grant is missing, and the tray Grant item
                              // stays visible — a background push would double-signal (and can't tell a
                              // still-open prompt from a real denial). Let those surfaces own it.
                              suppressBackgroundAlert: true))
    }
    // Notifications OFF means the outage (#27) and health (#32) push alerts silently never arrive — say
    // so in-app (this can't be a push, obviously). suppressBackgroundAlert for that same reason.
    if i.notificationsDenied {
        rows.append(HealthRow(group: "Permissions", title: "Notifications",
                              detail: "Off — macrec's outage and health alerts won't reach you. Turn them on in System Settings.",
                              level: .warn, action: .openNotificationSettings, suppressBackgroundAlert: true))
    }

    // ---- Pipeline ----
    if i.modelReady {
        rows.append(HealthRow(group: "Pipeline", title: "Model", detail: "\(i.modelName) · ready",
                              level: .ok, action: .none))
    } else {
        rows.append(HealthRow(group: "Pipeline", title: "Model",
                              detail: i.modelDownloading ? "\(i.modelName) · downloading…" : "\(i.modelName) · not downloaded",
                              level: i.modelDownloading ? .warn : .bad,
                              action: i.modelDownloading ? .none : .openSettings(pane: "Model")))
    }
    if !i.whisperResolved {
        rows.append(HealthRow(group: "Pipeline", title: "whisper-cli", detail: "Not found on PATH.",
                              level: .bad, action: .openSettings(pane: "Transcripts")))
    }
    // The summary runner row — only meaningful when summaries are on.
    switch i.summary {
    case .off:
        break
    case .idle:
        rows.append(pipelineRunnerRow(i, detail: "after the next transcript"))
    case .running(let f):
        rows.append(HealthRow(group: "Pipeline", title: "Summary", detail: "running… \(f)",
                              level: .warn, action: .none))
    case .done(let f, _):
        rows.append(HealthRow(group: "Pipeline", title: "Summary", detail: "last: \(f)",
                              level: .ok, action: .none))
    case .failed(let f, _, let reason):
        rows.append(HealthRow(group: "Pipeline", title: "Summary FAILED",
                              detail: "\(f) — \(reason ?? "unknown reason")", level: .bad, action: .retrySummary,
                              suppressBackgroundAlert: true))   // the pipeline already pushes its own "Summary failed"
    }

    // ---- Today ----
    rows.append(HealthRow(group: "Today", title: "Transcribed",
                          detail: "\(i.transcriptsToday) transcript\(i.transcriptsToday == 1 ? "" : "s"), \(i.summariesToday) summarized",
                          level: .ok, action: .none))
    if i.digestEnabled {
        let overdue = digestOverdue(now: i.now, time: i.digestTime, ranToday: i.digestRanToday)
        rows.append(HealthRow(group: "Today", title: "Daily digest",
                              detail: i.digestRanToday ? "written today"
                                  : overdue ? "overdue (due \(i.digestTime))" : "due at \(i.digestTime)",
                              level: overdue ? .warn : .ok, action: .none))
    }
    return rows
}

/// Which BAD health conditions are NEW alerts to push so a CLOSED Today window still warns (#32).
/// DEBOUNCED: a condition must be bad on TWO consecutive samples before it alerts, so a legitimate
/// transient — an engine restart on a schedule/calendar resume momentarily has `engine == nil`, a boot
/// state still settling — rides over without a false alert (it clears by the next tick and is never
/// confirmed). A condition alerts once; it must clear and recur to alert again (no spam). Rows that
/// self-surface elsewhere (`suppressBackgroundAlert`: the pipeline's own failure push, the OS
/// permission prompt) never alert here. Returns the new alerts + the two sets to carry forward.
/// Pure + selftested; the caller adds a startup grace and suppresses while the window is visible.
func healthAlerts(rows: [HealthRow], lastBad: Set<String>, alerted: Set<String>)
    -> (new: [HealthRow], bad: Set<String>, alerted: Set<String>) {
    func key(_ r: HealthRow) -> String { "\(r.group)/\(r.title)" }
    let badRows = rows.filter { $0.level == .bad && !$0.suppressBackgroundAlert }
    let bad = Set(badRows.map(key))
    let confirmed = bad.intersection(lastBad)                       // bad for two consecutive samples
    let new = badRows.filter { confirmed.contains(key($0)) && !alerted.contains(key($0)) }
    let stillAlerted = alerted.intersection(bad).union(Set(new.map(key)))   // a cleared condition drops → can re-alert
    return (new, bad, stillAlerted)
}

private func pipelineRunnerRow(_ i: HealthInputs, detail: String) -> HealthRow {
    i.runnerResolved
        ? HealthRow(group: "Pipeline", title: "Summary runner", detail: "\(i.runnerName) · \(detail)", level: .ok, action: .none)
        : HealthRow(group: "Pipeline", title: "Summary runner", detail: "\(i.runnerName) not found on PATH.",
                    level: .bad, action: .openSettings(pane: "Post-processing"))
}

/// The overall verdict the tray line and the dashboard header share — the WORST row wins, so the
/// two surfaces can never contradict (enablement and action are one decision).
func overallHealth(_ rows: [HealthRow]) -> (level: HealthLevel, line: String) {
    guard let worst = rows.map(\.level).max() else { return (.ok, "No signals yet.") }
    switch worst {
    case .ok: return (.ok, "Everything's recording and healthy.")
    case .warn:
        let w = rows.first { $0.level == .warn }
        return (.warn, w.map { "\($0.title): \($0.detail)" } ?? "Something needs attention.")
    case .bad:
        let b = rows.first { $0.level == .bad }
        return (.bad, b.map { "\($0.title): \($0.detail)" } ?? "Something is broken.")
    }
}

/// The digest is overdue when now is past today's HH:mm and it hasn't run yet. Pure (mirrors
/// dailyDigestDue's boundary without the last-run string coupling).
func digestOverdue(now: Date, time: String, ranToday: Bool, calendar: Calendar = .current) -> Bool {
    guard !ranToday else { return false }
    let hm = time.split(separator: ":").compactMap { Int($0) }
    guard hm.count == 2, (0 ..< 24).contains(hm[0]), (0 ..< 60).contains(hm[1]) else { return false }
    let mins = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
    return mins >= hm[0] * 60 + hm[1]
}

/// yyyy-MM-dd for `now` (the digest last-run marker's format).
func todayString(_ now: Date = Date(), calendar: Calendar = .current) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"
    return f.string(from: now)
}

/// How many transcripts/summaries carry today's date — count file NAMES, so the panel doesn't read
/// a byte of content. A transcript stem is `YYYY-MM-DD-HHMM…` (a time follows the date), so the
/// bare-date daily-digest file (`YYYY-MM-DD`) and side-by-side `-sum` summaries are excluded.
/// `sideBySide` = the summary dir IS the transcript tree (the default): then a summary is a `-sum`
/// file, mirroring LibraryIndex — otherwise every transcript would count as its own summary.
func todayOutputCounts(transcriptStems: [String], summaryStems: [String], day: String,
                       summariesSideBySide: Bool) -> (transcripts: Int, summaries: Int) {
    func timestampedToday(_ s: String) -> Bool { s.hasPrefix(day + "-") } // has a time after the date
    let transcripts = transcriptStems.filter { timestampedToday($0) && !$0.hasSuffix("-sum") }.count
    let summaries = summaryStems.filter {
        timestampedToday($0) && (summariesSideBySide ? $0.hasSuffix("-sum") : !$0.hasSuffix("-sum"))
    }.count
    return (transcripts, summaries)
}
