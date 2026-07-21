import AppKit
import Foundation

// MARK: - process-liveness heartbeat + silent-outage detection (#27)
//
// The recorder is a launchd agent that relaunches only on a CRASH (KeepAlive SuccessfulExit=false):
// a clean exit or an external stop (bootout, a failed reinstall) leaves the PROCESS dead until the
// next login/kickstart. That is how an 18-hour overnight+morning outage once dropped a real meeting
// with NOTHING shown. We can't force a relaunch without breaking "a deliberate Quit stays quit" —
// but a silent failure is the worst failure, so we make the outage LOUD after the fact.
//
// Liveness is proven by a heartbeat pref written every `interval` seconds for the whole APP-PROCESS
// lifetime — NOT tied to the engine. A paused or schedule-parked recorder keeps the process (and the
// beat) alive, so an intentional idle window never looks like a gap; only the process actually dying
// creates one. The forgiving `cleanStop` marker is written ONLY on a genuine user Quit — never on a
// pause, a schedule park, a settings restart, or an OS SIGTERM/bootout — so the very bootout-death
// this feature exists to catch is surfaced, not swallowed. Everything decidable is the pure
// `recorderOutage`; the I/O (pref reads/writes, the 60s timer) is the thin shell around it.

/// The real downtime to surface, or nil when the gap is benign. Pure — every world value is injected.
/// Benign = first-ever run, a backward clock (negative/tiny gap), the mac was off/rebooted during the
/// gap (`bootTime >= last`), or a deliberate Quit right before it (`cleanStop` adjacent to the last
/// beat). `minGapSeconds` is the floor below which a gap isn't worth reporting at all (dev kickstarts,
/// crash-relaunches — both sub-minute); the CALLER decides log-quietly vs. alert-loudly above it.
func recorderOutage(lastHeartbeat: Date?, cleanStop: Date?, now: Date, bootTime: Date,
                    minGapSeconds: TimeInterval = 300,
                    heartbeatSeconds: TimeInterval = 60) -> TimeInterval? {
    guard let last = lastHeartbeat else { return nil }          // never ran before — nothing to compare
    let gap = now.timeIntervalSince(last)
    guard gap >= minGapSeconds else { return nil }              // a quick restart / backward clock
    if bootTime >= last { return nil }                          // the mac booted at/after our last beat → it was off
    // A deliberate Quit writes cleanStop right after the final beat, so it sits adjacent to `last`.
    // Only THAT is forgiven — and only while `last` hasn't advanced past it (a later run's beats make
    // an old cleanStop stale, so it can't blind a fresh crash-outage).
    if let stop = cleanStop, abs(stop.timeIntervalSince(last)) <= heartbeatSeconds * 2 { return nil }
    return gap
}

/// The watchdog's decision (#36b): relaunch the recorder ONLY when it's down AND the user didn't
/// deliberately Quit it. A crash, an OS memory-pressure/idle kill, or a failed install leaves no quit
/// flag, so the recorder is brought back within the watchdog's 60 s interval — whatever killed it. A
/// menu Quit sets the flag (cleared on the next launch), so "a deliberate Quit stays quit". Pure.
func watchdogShouldRelaunch(mainRunning: Bool, quitRequested: Bool) -> Bool {
    !mainRunning && !quitRequested
}

/// One watchdog check: is the recorder down (no deliberate Quit)? Relaunch it if so. The thin I/O shell
/// around `watchdogShouldRelaunch` — reads the live process list + the quit flag, kicks launchd on a
/// verdict. Liveness is the GUI-registered recorder only: this daemon is a plain Foundation process, so
/// it never appears in `runningApplications(bid)` and can't see itself as "the recorder is up".
func watchdogCheckOnce(d: UserDefaults = Pref.d, log: (String) -> Void = { elog($0) }) {
    let bid = Bundle.main.bundleIdentifier ?? "com.ikhoon.macrec"
    let selfPid = ProcessInfo.processInfo.processIdentifier
    let mainRunning = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        .contains { $0.processIdentifier != selfPid }
    guard watchdogShouldRelaunch(mainRunning: mainRunning,
                                 quitRequested: d.bool(forKey: Pref.watchdogQuitRequested)) else { return }
    log("watchdog: recorder is down (no deliberate Quit) — relaunching")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["kickstart", "gui/\(getuid())/com.ikhoon.macrec"]
    try? p.run(); p.waitUntilExit()
}

/// A gap in seconds → a short human string for the log/notification/panel ("18 h", "45 min", "2 h 10 min").
func humanDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded()))
    if s < 90 { return "\(s) s" }
    let mins = s / 60
    if mins < 90 { return "\(mins) min" }
    let h = mins / 60, m = mins % 60
    return m == 0 ? "\(h) h" : "\(h) h \(m) min"
}

/// A human "from–to" window for an outage (the notification/log). Includes the date when the window
/// spans local days — an overnight outage is the common case, and "23:00–08:00" alone would mislead.
/// Pure + testable; 24-hour clock to match the app's other status rows.
func outageWindowText(from: Date, to: Date, calendar: Calendar = .current) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = calendar; f.timeZone = calendar.timeZone
    f.dateFormat = calendar.isDate(from, inSameDayAs: to) ? "HH:mm" : "MMM d HH:mm"
    return "\(f.string(from: from))–\(f.string(from: to))"
}

/// The tray menu's outage status line, or "" when there's nothing to show today. Pure + testable.
func outageMenuTitle(outageSeconds: Double) -> String {
    outageSeconds > 0 ? "⚠︎ Recorder was down ~\(humanDuration(outageSeconds)) today" : ""
}

/// Thin I/O shell: read the prior stamps, decide, persist the verdict, and keep the heartbeat ticking.
/// The app calls `checkOutageOnStart()` once at launch (before the first beat), then `start()`; it
/// `beat()`s on wake; `noteUserQuit()` on a real Quit. The Today panel + tray read `outageForToday()`.
enum RecorderHeartbeat {
    private static var timer: DispatchSourceTimer?
    static let interval: TimeInterval = 60
    /// A gap this long or longer is surfaced LOUDLY (notification + Today row + menu line). A shorter
    /// but real gap is only logged — enough that support / `outage-check` can see it, without a
    /// notification for every brief hiccup.
    static let surfaceThresholdSeconds: TimeInterval = 1800

    /// Decide + (for a surfaced outage) persist the verdict for a fresh app launch, BEFORE the first
    /// heartbeat overwrites the prior run's last beat. Returns the downtime to SURFACE loudly (also
    /// stored for the Today panel + menu), or nil. A shorter-but-real gap is logged quietly → nil.
    @discardableResult
    static func checkOutageOnStart(now: Date = Date(),
                                   uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                                   d: UserDefaults = Pref.d,
                                   log: (String) -> Void = { elog($0) }) -> TimeInterval? {
        guard let gap = recorderOutage(lastHeartbeat: stamp(Pref.recorderHeartbeat, d),
                                       cleanStop: stamp(Pref.recorderCleanStop, d),
                                       now: now, bootTime: now.addingTimeInterval(-uptime),
                                       heartbeatSeconds: interval) else { return nil }
        guard gap >= surfaceThresholdSeconds else {
            log("heartbeat: recorder was down ~\(humanDuration(gap)) (under the \(Int(surfaceThresholdSeconds / 60))-min alert bar) — logged only")
            return nil
        }
        d.set(now.timeIntervalSince1970, forKey: Pref.recorderOutageAt)
        d.set(gap, forKey: Pref.recorderOutageSeconds)
        return gap
    }

    /// Write a liveness stamp — proof the app process was alive at `now`.
    static func beat(now: Date = Date(), d: UserDefaults = Pref.d) {
        d.set(now.timeIntervalSince1970, forKey: Pref.recorderHeartbeat)
    }

    /// Begin the process-lifetime heartbeat. Idempotent — cancels any prior timer first (a resumed
    /// DispatchSource keeps firing until cancelled, so replacing the ref without cancel would leak it).
    static func start(queue: DispatchQueue) {
        timer?.cancel()
        beat()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { beat() }
        t.resume()
        timer = t
    }

    /// A genuine user Quit — stop the heartbeat and record a clean stop so the next launch doesn't cry
    /// outage over an intentional exit. Deliberately NOT called for pause / schedule-park / SIGTERM.
    static func noteUserQuit(now: Date = Date(), d: UserDefaults = Pref.d) {
        timer?.cancel(); timer = nil
        d.set(now.timeIntervalSince1970, forKey: Pref.recorderCleanStop)
    }

    /// The outage the Today panel + tray should show: the last surfaced downtime IF it was detected
    /// today (so it clears itself the next local day). Returns seconds, or 0 when there's nothing.
    static func outageForToday(now: Date = Date(), d: UserDefaults = Pref.d, calendar: Calendar = .current) -> Double {
        let at = d.double(forKey: Pref.recorderOutageAt)
        guard at > 0,
              todayString(Date(timeIntervalSince1970: at), calendar: calendar) == todayString(now, calendar: calendar)
        else { return 0 }
        return d.double(forKey: Pref.recorderOutageSeconds)
    }

    private static func stamp(_ key: String, _ d: UserDefaults) -> Date? {
        let v = d.double(forKey: key)
        return v > 0 ? Date(timeIntervalSince1970: v) : nil
    }
}
