import AppKit
import AVFoundation
import Foundation
import UserNotifications

/// The menu-bar app: owns the status item + menu, the recording engine's lifecycle, and the
/// schedule/calendar recording gate.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var engine: RecordingEngine?
    private var stopTask: Task<Void, Never>?   // in-flight engine stop (pause) — resume/restart await it so
                                               // two capture pipelines never overlap on the shared audio state
    private var voiceTimer: Timer?             // ~1 Hz poll for the voice-activity tray tint
    private var schedTimer: Timer?             // ~30 s recording-schedule enforcement
    private var notifyWhenTranscribed = false  // armed by "Transcribe now" — the menu closed, push the outcome
    private var lastTranscriptURL: URL?        // most recent saved transcript (notification click opens it)
    private var flushBusy = false              // one manual flush at a time; the row spinner shows progress
    private var flushGeneration = 0            // failsafe-timeout token (a new flush invalidates old timers)
    private var transcribeBtn: NSButton!               // "Transcribe now" row (view-backed: menu stays open)
    private let menuRowSpinner = NSProgressIndicator() // replaces the row's icon while the flush runs
    private var transcribeRowTitle = "Transcribe now"  // flashes the outcome ("No speech found") briefly
    private var rowHovered = false                     // hover restyle must not clobber a flashed title
    private var spinStartedAt: TimeInterval = 0        // enforce a visible minimum spin (see spinnerHold)
    private var schedulePaused = false         // the recording window (schedule OR calendar) stopped it
    private var schedulePauseReason: RecordPause?  // which gate — so the tray message updates if it flips
    private var scheduleOverrideUntil: Date?   // manual Pause/Resume wins until this boundary passes
    private var startTask: Task<Void, Never>?  // in-flight engine start — stops must wait for it
    private var voiceShown = false
    private var lastVoiceAt: TimeInterval = 0
    private var statusLine: NSMenuItem!
    private var levelItem: NSMenuItem!
    private var lastSavedLine: NSMenuItem!
    private var modelLine: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var liveItem: NSMenuItem?   // "Live captions" toggle (macOS 26+)
    private var summaryLine: NSMenuItem!   // what post-processing is doing, refreshed when the menu opens
    private var digestLine: NSMenuItem!
    private var pendingSummaryAction: SummaryRowAction = .none
    private let digestCoordinator = DigestCoordinator()   // the digest tick, extracted for scenario QA
    private var grantItem: NSMenuItem?  // "Grant permissions…" — shown ONLY while a permission is missing
    private var paused = false
    private var didAutoPrompt = false   // only auto-open the permission prompts/Settings once per launch
    private var checkingForUpdates = false   // a manual update check is in flight — don't stack modal alerts
    private var settingsWC: SettingsWindowController?
    private var levelTimer: Timer?
    private let heartbeatQueue = DispatchQueue(label: "com.ikhoon.macrec.heartbeat")   // #27: process-liveness beat
    private var outageLine: NSMenuItem!   // shown only after a same-day silent outage (durable surface)
    private var healthLine: NSMenuItem!   // shown only when a BAD health condition exists (menu-bar surface)
    private var alertedHealth: Set<String> = []   // #32: BAD conditions already pushed (dedup, re-alert on recurrence)
    private var lastBadHealth: Set<String> = []   // #32: BAD keys from the previous tick (2-tick debounce)
    private let launchedAt = Date()               // #32: startup grace so transient boot states don't alert
    private var notifDenied = false               // #33: notification auth is definitively denied (alerts won't arrive)
    private var realQuitRequested = false         // tray Quit / system stop — terminate really terminates
    private var recordingActivity: NSObjectProtocol?   // #36: held for the process lifetime so macOS won't reap the idle recorder

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: if a copy is already running (the LaunchAgent one), just tell it to open
        // its menu and quit this launch — so clicking the app in /Applications opens the tray menu.
        let bid = Bundle.main.bundleIdentifier ?? "com.ikhoon.macrec"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(
                .init("com.ikhoon.macrec.openMenu"), object: nil, deliverImmediately: true)
            NSApp.terminate(nil); return
        }
        // #36 (root cause of the recurring "macrec 꺼져있네" outage): an LSUIElement accessory app is a
        // candidate for macOS automatic/sudden termination when it looks idle. macrec exits 0 when reaped,
        // and launchd KeepAlive (SuccessfulExit=false) does NOT relaunch a clean exit — so it stays dead
        // (observed: DOWN 62 min, no crash report). Opt out for the whole session so the recorder isn't
        // reaped; the #27 heartbeat only DETECTED this — this prevents it. (System sleep is untouched: the
        // engine still suspends on sleep and resumes on wake.)
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("continuous meeting recording")
        recordingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "macrec records meetings continuously")
        Pref.d.removeObject(forKey: Pref.watchdogQuitRequested)   // #36b: we're running now — any prior Quit is void
        buildMenu()
        NSApp.mainMenu = Self.editShortcutMenu()   // wire ⌘X/C/V/A/Z app-wide (accessory apps have no Edit menu)
        // Credentials now live in a 0600 file (see Keychain), read lazily — no startup keychain access at
        // all, so nothing can prompt. Existing keys are re-entered once in Settings; the old login-keychain
        // items are simply never read again (harmless). `purgeLegacyKeychain` exists to tidy them but is NOT
        // called at launch, so a delete can't surface an "allow access" prompt.
        let vt = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.pollVoice() }
        RunLoop.main.add(vt, forMode: .common)   // .common so the tint updates while menus track too
        voiceTimer = vt
        let st = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.checkSchedule(); self?.maybeRunDailyDigest(); self?.maybeCheckForUpdates(); self?.checkHealthAlerts() }   // timer runs in .common; engine state is main-confined
        }
        RunLoop.main.add(st, forMode: .common)
        schedTimer = st
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.ikhoon.macrec.openMenu"), object: nil, queue: .main
        ) { [weak self] _ in self?.openMenu() }
        UNUserNotificationCenter.current().delegate = self   // click a completion push → open the file
        checkRecorderOutage()   // #27: was the process dead across a stretch while the mac was awake? say so LOUDLY
        // Process-liveness heartbeat for the whole run, independent of the engine (a paused/parked
        // recorder keeps the process alive, so an intentional idle never reads as a gap). Beat on wake
        // too, so a post-sleep death is measured from wake, not from before the sleep.
        RecorderHeartbeat.start(queue: heartbeatQueue)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [hbq = heartbeatQueue] _ in hbq.async { RecorderHeartbeat.beat() } }   // single-writer: all beats on hbq
        CalendarLookup.requestAccess()   // one-time Calendar prompt (for titling transcripts)
        setupModelDownload()             // first-run: fetch the large model, show progress in the menu
        LoginItem.autoEnableOnceIfDistributed()   // distributed app: enable 24/7 autostart on first run
        startEngineRespectingSchedule()           // a 23:00 login with a 10-19h schedule must NOT record
        installStopHandler { [weak self] in
            // `engine` is main-confined (voice poll, menu actions read it there) — the signal source
            // fires on its own queue, so hop to main before touching it (review finding: racy mutation).
            DispatchQueue.main.async {
                self?.realQuitRequested = true   // a system stop must terminate — never be downgraded to window-close
                self?.stopEngineSync()
                NSApp.terminate(nil)
            }
        }
    }

    private func setIcon(recording: Bool, voice: Bool = false) {
        // The macrec menu-bar mark (waveform-mic glyph, template) — adapts to light/dark, no colored tile
        // (user: drop the blue background). Voice tints light orange; paused/idle dims it (maccal-style).
        let img = brandMarkImage(side: 18, recording: recording, voice: voice)
        statusItem.button?.image = img
        statusItem.length = ceil(img.size.width) + 4
        if Pref.bool("trayDebug", "MR_TRAY_DEBUG", false) {
            elog("icon set (recording=\(recording), voice=\(voice)), length=\(statusItem.length)")
        }
    }

    /// Poll the engine's recent input levels (~1 Hz, negligible) and reflect "voice being picked up"
    /// in the tray glyph. 2 s hysteresis so normal speech pauses don't flicker the icon.
    private func pollVoice() {
        guard let eng = engine, !paused else {
            if voiceShown { voiceShown = false; setIcon(recording: engine != nil && !paused) }
            return
        }
        let (mic, sys) = eng.liveLevels()
        let now = ProcessInfo.processInfo.systemUptime
        if max(mic, sys) > 0.02 { lastVoiceAt = now }   // ≈ one meter dot — speech, not room noise
        let active = now - lastVoiceAt < 2.0
        if active != voiceShown { voiceShown = active; setIcon(recording: true, voice: active) }
    }

    private func item(_ title: String, _ sel: Selector, _ key: String = "", symbol: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key); i.target = self
        if !symbol.isEmpty { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        return i
    }

    /// The two CAPTURE grants that gate recording are in place (System Audio + Microphone) — used to
    /// hide "Grant permissions…" when there's nothing recording-critical left to grant (re-checked each
    /// menu open, so allowing them elsewhere clears it). Calendar is optional and intentionally excluded.
    private func allPermissionsGranted() -> Bool {
        captureGrantsSatisfied(audioGranted: audioCaptureAuthorized(), micGranted: micAuthorized())
    }

    /// Grey out "Pause" when nothing is recording to pause (off-hours / idle); the menu re-validates
    /// each time it opens. "Resume" (paused) stays enabled. Other items are unaffected.
    /// The menu auto-enables its items, so AppKit calls this AFTER menuWillOpen and it has the last word.
    /// Setting `isEnabled` directly on a target/action row is silently undone here.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === toggleItem { return pauseItemEnabled(paused: paused, schedulePaused: schedulePaused, hasEngine: engine != nil) }
        if menuItem === summaryLine { return pendingSummaryAction != .none }
        return true
    }

    private func buildMenu() {
        setIcon(recording: false)
        let menu = NSMenu()
        // Transcribe now keeps the menu OPEN while the status line swaps between
        // strings of different lengths ("● Transcribing…" → "● No speech —
        // skipped" → "● Recording · mic + system audio"). An NSMenu re-measures
        // its width per change, so the open menu visibly jiggles. Pin a minimum
        // width sized to the longest routine status so text swaps never resize it.
        let widestStatus = "⚠ Grant System Audio Recording + Microphone to macrec"
        let statusFont = NSFont.menuFont(ofSize: 0)
        menu.minimumWidth = (widestStatus as NSString)
            .size(withAttributes: [.font: statusFont]).width + 36 // item insets
        // About on top (macOS convention), then a divider.
        menu.addItem(item("About macrec", #selector(showAbout), symbol: "info.circle"))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates), symbol: "arrow.triangle.2.circlepath"))
        menu.addItem(.separator())
        // Live status rows (disabled — informational; they carry their own inline status glyphs).
        statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: ""); statusLine.isEnabled = false
        levelItem = NSMenuItem(title: "🎤 —   🔊 —", action: nil, keyEquivalent: ""); levelItem.isEnabled = false
        lastSavedLine = NSMenuItem(title: "", action: nil, keyEquivalent: ""); lastSavedLine.isEnabled = false; lastSavedLine.isHidden = true
        modelLine = NSMenuItem(title: "", action: nil, keyEquivalent: ""); modelLine.isEnabled = false; modelLine.isHidden = true
        // Post-processing used to leave no trace at all, so a working pipeline read as a broken one.
        summaryLine = NSMenuItem(title: "", action: #selector(revealLastSummary), keyEquivalent: "")
        summaryLine.target = self
        digestLine = NSMenuItem(title: "", action: nil, keyEquivalent: ""); digestLine.isEnabled = false
        // #27: a durable, always-visible outage line for the menu-bar-only user (who may never open the
        // Today panel). Clicking it opens the log where the "was DOWN" detail lives. Hidden until there's
        // a same-day outage to report.
        outageLine = NSMenuItem(title: "", action: #selector(showLog), keyEquivalent: "")
        outageLine.target = self; outageLine.isHidden = true
        // The menu-bar user's surface for a BROKEN pipeline (tool/model missing, capture silent, not
        // recording): the menu is what they see, and with notifications off they get no push. Clicking
        // opens Today for the detail + fix. Hidden while everything is healthy, so the menu stays clean.
        healthLine = NSMenuItem(title: "", action: #selector(openToday), keyEquivalent: "")
        healthLine.target = self; healthLine.isHidden = true
        menu.addItem(statusLine); menu.addItem(levelItem); menu.addItem(lastSavedLine); menu.addItem(modelLine)
        menu.addItem(summaryLine); menu.addItem(digestLine); menu.addItem(outageLine); menu.addItem(healthLine)
        menu.addItem(.separator())
        // Transcribe now — view-backed so the click does NOT dismiss the menu (user pick, round 2:
        // stay open and watch the row's spinner in place). MenuHoverView supplies the native-style
        // hover pill AppKit withholds from view-backed items; the completion push still fires for
        // whenever the menu IS closed while a flush runs.
        let tItem = NSMenuItem()
        let tView = MenuHoverView(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        let tBtn = NSButton(title: "Transcribe now", target: self, action: #selector(flushNow))
        tBtn.isBordered = false; tBtn.alignment = .left
        transcribeBtn = tBtn
        styleTranscribeRow()
        tView.onHover = { [weak self] hovered in
            self?.rowHovered = hovered
            self?.styleTranscribeRow()
        }
        tBtn.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "Transcribe now")
        tBtn.imagePosition = .imageLeading
        // AppKit's default image↔title gap matches the standard imaged items; a small left inset
        // lines the icon up with them.
        tBtn.frame = NSRect(x: 14, y: 1, width: 221, height: 20)
        tBtn.autoresizingMask = [.width]
        menuRowSpinner.style = .spinning
        menuRowSpinner.controlSize = .small
        menuRowSpinner.isDisplayedWhenStopped = false
        menuRowSpinner.frame = NSRect(x: 13, y: 3, width: 16, height: 16)   // sits where the icon was
        tView.addSubview(tBtn); tView.addSubview(menuRowSpinner); tItem.view = tView
        menu.addItem(tItem)
        toggleItem = item("Pause", #selector(togglePause), symbol: "pause.circle"); menu.addItem(toggleItem)
        if #available(macOS 26, *) {   // real-time caption overlay (on-device SpeechAnalyzer)
            let li = item("Live captions", #selector(toggleLive), symbol: "captions.bubble")
            li.state = LiveCaptions.shared.active ? .on : .off
            liveItem = li; menu.addItem(li)
        }
        menu.addItem(.separator())
        let grant = item("Grant permissions…", #selector(grantPermissions), symbol: "hand.raised")
        grant.isHidden = allPermissionsGranted()   // only surfaces when audio or mic is still missing
        grantItem = grant
        menu.addItem(grant)
        menu.addItem(item("Settings…", #selector(openSettings), ",", symbol: "gearshape"))
        menu.addItem(item("Status…", #selector(openToday), "d", symbol: "heart.text.square"))
        menu.addItem(item("Library…", #selector(openLibrary), "l", symbol: "books.vertical"))
        menu.addItem(item("Open transcripts folder", #selector(openTranscripts), "o", symbol: "folder"))
        menu.addItem(item("Show log", #selector(showLog), symbol: "text.alignleft"))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), "q", symbol: "power"))
        menu.delegate = self
        statusItem.menu = menu
    }

    // Live input meter — only updates while the menu is open (cheap, and answers "is it working?").
    /// The summary/digest rows, re-derived from prefs and live status every time the menu opens.
    private func refreshPostProcessRows() {
        let mode = effectivePostProcessMode(rawMode: Pref.explicit(Pref.postProcessMode, "MR_POST_PROCESS_MODE"),
                                            shellCmd: Pref.postProcessCommand)
        let (live, lastOut) = SummaryStatus.shared.snapshot
        let activity: SummaryActivity = mode == .off ? .off : live
        let hm = DateFormatter(); hm.locale = Locale(identifier: "en_US_POSIX"); hm.dateFormat = "HH:mm"
        summaryLine.title = summaryMenuTitle(activity) { hm.string(from: $0) }
        // Enablement is decided ONCE, in validateMenuItem, from this same action — assigning isEnabled
        // here would be overwritten by AppKit's validation pass.
        pendingSummaryAction = summaryRowAction(activity, lastOutput: lastOut)

        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        digestLine.title = digestMenuTitle(enabled: Pref.bool(Pref.dailyDigest, "MR_DAILY_DIGEST", false),
                                           dueTime: Pref.str(Pref.dailyDigestTime, "MR_DAILY_DIGEST_TIME", "20:00"),
                                           lastRun: Pref.explicit(Pref.dailyDigestLastRun, ""),
                                           today: day.string(from: Date()))
        let outageTitle = outageMenuTitle(outageSeconds: RecorderHeartbeat.outageForToday())
        outageLine.title = outageTitle; outageLine.isHidden = outageTitle.isEmpty
        let healthTitle = menuHealthLine(todayHealth(sampleHealth()))
        healthLine.title = healthTitle; healthLine.isHidden = healthTitle.isEmpty
    }

    /// Drives the REAL buildMenu + menuWillOpen and reports the two post-process rows. A deleted call to
    /// `refreshPostProcessRows` or a renamed selector then leaves the rows frozen and turns the selftest
    /// red — asserting that a function merely EXISTS proves nothing about it being wired.
    func postProcessRowsAfterMenuOpenForTest() -> (summary: String, digest: String, enabled: Bool)? {
        buildMenu()
        guard let menu = statusItem.menu else { return nil }
        menuWillOpen(menu)
        // The menu auto-enables its items: AppKit re-validates every target/action item AFTER
        // menuWillOpen, so reading `isEnabled` here without an update() pass reads back the value we
        // just assigned, not the one the user sees. Drive the real validation.
        menu.update()
        menu.cancelTracking()
        guard let s = summaryLine, let d = digestLine else { return nil }
        return (s.title, d.title, s.isEnabled)
    }

    /// #27: drives the REAL menu build + open and reports the outage line's rendered state — proves the
    /// durable menu-bar surface is actually WIRED (title set, un-hidden, clickable) from the persisted
    /// outage, not just that outageMenuTitle returns a string. Reads the live pref, so set it first.
    func outageMenuLineAfterMenuOpenForTest() -> (title: String, hidden: Bool, enabled: Bool)? {
        buildMenu()
        guard let menu = statusItem.menu else { return nil }
        menuWillOpen(menu)
        menu.update()   // AppKit re-validates target/action items — read isEnabled AFTER, as the user sees it
        menu.cancelTracking()
        guard let o = outageLine else { return nil }
        return (o.title, o.isHidden, o.isEnabled)
    }

    /// #33 follow-up: drive the real menu build + open and report the health line — proves it's WIRED
    /// (refreshPostProcessRows sets it from live health) and clickable → Today. In the selftest env
    /// there's no engine, so sampleHealth yields "Not recording" (.bad) and the line must appear.
    func healthMenuLineAfterMenuOpenForTest() -> (title: String, hidden: Bool, opensToday: Bool)? {
        buildMenu()
        guard let menu = statusItem.menu else { return nil }
        menuWillOpen(menu)
        menu.update()
        menu.cancelTracking()
        guard let h = healthLine else { return nil }
        return (h.title, h.isHidden, h.action == #selector(openToday) && h.target != nil)
    }

    /// Clicking the summary row: reveal what it wrote, or explain why it didn't. Never nothing.
    @objc private func revealLastSummary() {
        switch pendingSummaryAction {
        case .none:
            break
        case .reveal(let path):
            // Show the summary IN-APP (Library renders the markdown) rather than bouncing to Finder —
            // the user reaches for the note, not the file (user request).
            LibraryWindow.shared.show(selecting: URL(fileURLWithPath: path))
        case .explain(let file, let reason):
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Summary failed for \(file)"
            a.informativeText = reason ?? "The summary runner exited with an error and wrote nothing. "
                + "Check the runner in Settings › Summaries."
            a.alertStyle = .warning
            a.addButton(withTitle: "Open Settings")
            a.addButton(withTitle: "Close").keyEquivalent = "\u{1b}"
            if a.runModal() == .alertFirstButtonReturn { openSettings() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Opt-in tray diagnostics (`defaults write com.ikhoon.macrec.prefs trayDebug -bool true`): the
        // menu anchors to the status button's WINDOW — if it ever opens detached (screen edge, the
        // reported multi-display bug), this frame is the evidence. The probe file additionally lets a
        // remote diagnostic open+auto-close the menu (`touch /tmp/macrec-tray-probe && open -a macrec`).
        if Pref.bool("trayDebug", "MR_TRAY_DEBUG", false) {
            if let win = statusItem.button?.window {
                let screens = NSScreen.screens.map { "(\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))×\(Int($0.frame.height)))" }.joined(separator: " ")
                elog("tray-diag open: btnWin=\(NSStringFromRect(win.frame)) onScreen=\(NSStringFromRect(win.screen?.frame ?? .zero)) mouse=\(NSStringFromPoint(NSEvent.mouseLocation)) len=\(statusItem.length) vis=\(statusItem.isVisible) screens=\(screens)")
            }
            if FileManager.default.fileExists(atPath: "/tmp/macrec-tray-probe") {
                try? FileManager.default.removeItem(atPath: "/tmp/macrec-tray-probe")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { menu.cancelTracking() }
            }
        }
        updateLevels()
        // Reflect the live-captions state in case it was turned off by closing the floating panel.
        if #available(macOS 26, *) { liveItem?.state = LiveCaptions.shared.active ? .on : .off }
        // Hide "Grant permissions…" once both grants are in place (re-checked each open — the user may
        // have just allowed them in System Settings). It reappears if a grant is ever revoked.
        grantItem?.isHidden = allPermissionsGranted()
        refreshPostProcessRows()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.updateLevels() }
        RunLoop.main.add(t, forMode: .eventTracking)   // fires while the menu is tracking
        levelTimer = t
    }
    func menuDidClose(_ menu: NSMenu) { levelTimer?.invalidate(); levelTimer = nil }

    private func meter(_ v: Float) -> String {
        let n = min(8, max(0, Int(min(1, v * 4) * 8)))   // speech peaks ~0.1–0.5 → some gain
        // ●/○ are a same-width pair (▰/▱ rendered at different sizes in the menu font).
        return String(repeating: "●", count: n) + String(repeating: "○", count: 8 - n)
    }

    private func updateLevels() {
        guard let eng = engine, !paused else { levelItem.title = "🎤 —   🔊 —"; return }
        let (mic, sys) = eng.liveLevels()
        levelItem.title = "🎤 \(meter(mic))  🔊 \(meter(sys))"
    }

    private func refresh(_ status: String) {
        statusLine?.title = status
        // Label + icon route through the SAME decision as the click and the enablement, so they can't
        // disagree (see togglePauseShouldResume).
        let stoppedByUs = togglePauseShouldResume(paused: paused, schedulePaused: schedulePaused)
        toggleItem?.title = stoppedByUs ? "Resume" : "Pause"
        toggleItem?.image = NSImage(systemSymbolName: stoppedByUs ? "play.circle" : "pause.circle", accessibilityDescription: nil)
    }

    /// First-run model download (the large model is too big to bundle). Surfaces progress in the menu;
    /// the engine transcribes automatically once the file lands (it re-checks per segment).
    private func setupModelDownload() {
        ModelStore.shared.onProgress = { [weak self] p in
            guard let self = self else { return }
            if p >= 1.0 {
                self.modelLine.title = "✓ Model ready"; self.modelLine.isHidden = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.modelLine.isHidden = true }
            } else if p < 0 {
                self.modelLine.title = "⚠ Model download failed — retries on restart"; self.modelLine.isHidden = false
            } else {
                self.modelLine.title = String(format: "⤓ Downloading model… %.0f%%", p * 100); self.modelLine.isHidden = false
            }
        }
        if ModelStore.shared.isReady {
            modelLine.isHidden = true
        } else {
            modelLine.title = "⤓ Preparing model…"; modelLine.isHidden = false
        }
        ModelStore.shared.ensure()
    }

    private func startEngine() {
        let eng = RecordingEngine(cfg: EngineConfig.load())   // reload prefs each start so settings apply
        eng.onSegmentResult = { [weak self] msg in
            DispatchQueue.main.async {
                if self?.paused == false { self?.statusLine.title = "● \(msg)" }
                self?.pushFlushOutcomeIfNeeded(msg)
            }
        }
        eng.onTranscriptURL = { [weak self] url in
            DispatchQueue.main.async { self?.lastTranscriptURL = url }   // before onTranscriptSaved (FIFO)
        }
        eng.onTranscriptSaved = { [weak self] msg in
            DispatchQueue.main.async {
                self?.lastSavedLine.title = "✓ \(msg)"; self?.lastSavedLine.isHidden = false
                if self?.paused == false { self?.statusLine.title = "● Recording · mic + system audio" }
                self?.pushFlushOutcomeIfNeeded(msg)
                LibraryWindow.shared.noteLibraryChanged()   // a new file just landed — refresh the open library
                TodayWindow.shared.noteChanged()             // the Today counts changed
            }
        }
        engine = eng
        startTask = Task {   // kept so stop paths can AWAIT the start — stopping mid-start would
            do {             // no-op (nothing to tear down yet) and orphan a live capture pipeline
                try await eng.start()
                await MainActor.run {
                    guard self.engine === eng else { return }   // stopped while starting — don't repaint
                    self.paused = false; self.setIcon(recording: true); self.refresh("● Recording · mic + system audio")
                }
            } catch {
                await MainActor.run {
                    self.engine = nil; self.setIcon(recording: false)
                    self.refresh("⚠ Grant System Audio Recording + Microphone to macrec")
                    if !self.didAutoPrompt { self.didAutoPrompt = true; self.grantPermissions() }  // fire prompts + open Settings once
                }
            }
        }
    }

    /// Start the engine unless the schedule says these are off-hours — in which case park in
    /// schedule-pause WITHOUT starting. Gating the start (instead of start-then-stop) is what keeps
    /// stop() from racing an in-flight start() at launch / settings-save time.
    private func startEngineRespectingSchedule() {
        if let pause = recordingWindowPauseNow(overriding: scheduleOverrideUntil != nil, now: Date()) {
            schedulePaused = true
            schedulePauseReason = pause
            setIcon(recording: false)
            refresh(pauseMessage(pause))
            elog("engine: not started — \(pauseReason(pause))")
        } else if !paused, engine == nil {
            startEngine()
        }
    }

    private func pauseReason(_ p: RecordPause) -> String {
        switch p {
        case .offHours: return "off-hours (schedule)"
        case .noMeeting: return "no live calendar meeting"
        }
    }

    @objc private func openLibrary() { LibraryWindow.shared.show() }

    @objc private func openToday() {
        let t = TodayWindow.shared
        t.sampleInputs = { [weak self] in self?.sampleHealth() ?? HealthInputs() }
        t.onGrant = { [weak self] in self?.grantPermissions() }
        t.onOpenSettings = { [weak self] _ in self?.openSettings() }
        t.onRetrySummary = { [weak self] in self?.flushNow() }
        t.onTestCapture = { [weak self] in self?.runCaptureTest() }
        t.onShowLog = { [weak self] in self?.showLog() }
        t.onOpenNotificationSettings = {
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") { NSWorkspace.shared.open(u) }
        }
        t.onWillRefresh = { [weak self] in self?.refreshToolCacheAsync() }
        refreshToolCacheAsync()   // warm the cache before the first render
        refreshNotifAuth()        // and the notification-auth verdict (#33)
        t.show()
    }

    /// The definitive muted-tap check: play a tone and see whether the RUNNING recorder's system
    /// level responds. Passive sampling can't tell a quiet room from a dead tap; this can. Runs off
    /// the main thread; the verdict feeds todayCaptureTest and re-renders.
    private func runCaptureTest() {
        guard engine?.running == true else {   // nothing is recording → the test can't observe capture
            todayCaptureTest = .untested
            TodayWindow.shared.noteChanged()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["-v", "0.3", "-t", "1.5", "/System/Library/Sounds/Submarine.aiff"]
            try? player.run()
            var peak: Float = 0
            let deadline = Date().addingTimeInterval(1.6)
            while Date() < deadline {
                peak = max(peak, self?.engine?.liveLevels().sys ?? 0)
                Thread.sleep(forTimeInterval: 0.05)
            }
            player.waitUntilExit()
            let verdict: CaptureTest = peak > 0.02 ? .captured : .silent
            DispatchQueue.main.async {
                self?.todayCaptureTest = verdict
                TodayWindow.shared.noteChanged()
            }
        }
    }

    /// #33: cache whether notification auth is DEFINITIVELY denied (async — the system settings query
    /// has a completion handler). Only `.denied` counts; `.notDetermined` will still be prompted, so it
    /// must not warn. Cheap; refreshed on the health tick + window open. Re-renders Today on a change.
    private func refreshNotifAuth() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] s in
            let denied = s.authorizationStatus == .denied
            DispatchQueue.main.async {
                guard let self, self.notifDenied != denied else { return }
                self.notifDenied = denied
                elog("notify: authorization \(denied ? "denied — alerts won't reach the user" : "allowed")")
                TodayWindow.shared.noteChanged()
            }
        }
    }

    /// #32: a closed Today window used to hide every silent failure it exists to surface. Every 30 s
    /// (the schedule tick), if a BAD health condition is present, push it as a notification — deduped so
    /// a persistent one alerts once, re-alerting only if it clears and recurs. A startup grace skips
    /// transient boot states; an open window is already showing them, so don't double-signal.
    private func checkHealthAlerts() {
        refreshNotifAuth()   // keep the "notifications off" verdict fresh even while the window is closed
        guard Date().timeIntervalSince(launchedAt) > 90, !TodayWindow.shared.isVisible else { return }
        // Keep whisper/runner resolution warm so "not found" can alert too — but on a 5-min window, not
        // the interactive 30s one: a resolved tool almost never un-resolves mid-run, so re-spawning two
        // login shells every tick forever is wasted background churn (review finding).
        refreshToolCacheAsync(maxAge: 300)
        let (new, bad, alerted) = healthAlerts(rows: todayHealth(sampleHealth()), lastBad: lastBadHealth, alerted: alertedHealth)
        lastBadHealth = bad; alertedHealth = alerted
        for row in new {
            elog("health: alerting (window closed) — \(row.title): \(row.detail)")
            Notifier.push(title: "macrec: \(row.title)", body: row.detail, openWindow: "today")
        }
    }

    /// Sample the live app into the dashboard's pure inputs (see TodayHealth). Cheap — re-run each tick.
    private func sampleHealth() -> HealthInputs {
        var h = HealthInputs()
        h.audioGranted = audioCaptureAuthorized(); h.micGranted = micAuthorized()
        h.calendarGranted = CalendarLookup.authorized
        h.recording = engine?.running == true && !paused && !schedulePaused
        h.paused = paused || schedulePaused
        let lv = engine?.liveLevels() ?? (mic: 0, sys: 0)
        h.micLevel = lv.mic; h.sysLevel = lv.sys
        h.captureTest = todayCaptureTest   // set only by the Test… button; passive = .untested
        h.modelReady = ModelStore.shared.isReady; h.modelName = WhisperCatalog.selected.name
        h.modelDownloading = ModelStore.shared.isDownloading
        let runner = SummaryRunner(rawValue: Pref.explicit(Pref.summaryRunner, "MR_SUMMARY_RUNNER")) ?? .claude
        h.runnerName = runner.rawValue
        // Tool resolution spawns a login shell — NEVER on the render path (main thread, 1 Hz).
        // A background refresh (see openToday) keeps this cache warm; until it lands, assume
        // resolved so a healthy setup doesn't flash red on first open.
        let tools = toolCache?.value ?? (whisper: true, runner: true)
        h.whisperResolved = tools.whisper; h.runnerResolved = tools.runner
        h.summary = SummaryStatus.shared.snapshot.0
        let day = todayString()
        let txDir = Pref.str(Pref.txtDir, "MR_TRANSCRIPTS_DIR", NSHomeDirectory() + "/Documents/macrec/transcripts")
        let sumPref = Pref.explicit(Pref.summaryOut, "MR_SUMMARY_OUT")
        let sideBySide = sumPref.isEmpty
        let sumDir = sideBySide ? txDir : sumPref
        // Only this month's folder can hold today's files — don't walk the whole multi-month tree
        // every 1 Hz tick (review finding).
        let month = String(day.prefix(7))
        let counts = todayOutputCounts(transcriptStems: stemsInMonth(txDir, month: month),
                                       summaryStems: stemsInMonth(sumDir, month: month),
                                       day: day, summariesSideBySide: sideBySide)
        h.transcriptsToday = counts.transcripts; h.summariesToday = counts.summaries
        h.digestEnabled = Pref.bool(Pref.dailyDigest, "MR_DAILY_DIGEST", false)
        h.digestTime = Pref.str(Pref.dailyDigestTime, "MR_DAILY_DIGEST_TIME", "20:00")
        h.digestRanToday = Pref.explicit(Pref.dailyDigestLastRun, "") == todayString()
        h.outageSeconds = RecorderHeartbeat.outageForToday()
        h.capturedSilenceToday = CaptureSilence.detectedToday()
        h.notificationsDenied = notifDenied
        h.now = Date()
        return h
    }

    /// .md file stems (no extension) in a tree's YYYY-MM subfolder plus any root-level files —
    /// only the month that can contain today's output, so the 1 Hz sampler never walks the whole
    /// multi-month tree.
    private func stemsInMonth(_ root: String, month: String) -> [String] {
        let fm = FileManager.default
        func stems(_ dir: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }
        }
        return stems(root) + stems(root + "/" + month)
    }

    // Tool resolution result, refreshed on a BACKGROUND queue (each check spawns a login shell) so
    // the render path never blocks. nil until the first refresh completes.
    private var toolCache: (value: (whisper: Bool, runner: Bool), at: Date)?
    private var toolCacheRefreshing = false   // in-flight guard: a hung spawn must not pile up more (review)
    /// Resolve the whisper + runner CLIs off the main thread, cache the result, and re-render. Coalesced
    /// to at most once / `maxAge` s (the interactive window open uses 30 s; the background alert poll a
    /// longer window, since a resolved tool almost never un-resolves mid-run).
    private func refreshToolCacheAsync(maxAge: TimeInterval = 30) {
        if toolCacheRefreshing { return }
        if let c = toolCache, Date().timeIntervalSince(c.at) < maxAge { return }
        toolCacheRefreshing = true
        let whisper = Pref.str("whisperCli", "MR_WHISPER_CLI", BundledTools.whisperCli ?? "whisper-cli")
        let runner = (SummaryRunner(rawValue: Pref.explicit(Pref.summaryRunner, "MR_SUMMARY_RUNNER")) ?? .claude).rawValue
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let w = self.toolResolves(whisper), r = self.toolResolves(runner)
            DispatchQueue.main.async {
                self.toolCache = ((w, r), Date())
                self.toolCacheRefreshing = false
                TodayWindow.shared.noteChanged()
            }
        }
    }

    /// Does a summary-runner / whisper CLI resolve? An absolute path checks the file; a bare name is
    /// looked up with the EXACT environment the runners use (postProcessEnvironment prepends
    /// /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, ~/bin). Under launchd a bare `zsh -lc` sees
    /// none of those unless the user's PATH export happens to be in .zprofile — so resolving without
    /// that prepend falsely reported "claude not found" while the actual summary run finds it fine.
    private func toolResolves(_ nameOrPath: String) -> Bool {
        if nameOrPath.contains("/") { return FileManager.default.isExecutableFile(atPath: nameOrPath) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "command -v \(nameOrPath) >/dev/null 2>&1"]
        p.environment = postProcessEnvironment(for: nameOrPath)
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// The capture-test verdict, set by the Test… button (nil until run). Passive sampling leaves it.
    private var todayCaptureTest: CaptureTest = .untested

    @objc private func flushNow() {
        guard engine != nil, !paused, !flushBusy else { return }   // busy = one flush at a time
        notifyWhenTranscribed = true   // outcome arrives as a push (the menu may be closed by then)
        Notifier.requestAuth()         // no-op after the user answered the first prompt
        showFlushSpinner()             // the row's icon slot spins until the outcome lands
        engine?.flushNow()
        refresh("● Transcribing now…")
    }

    /// One push per armed "Transcribe now": the first TERMINAL status (saved / no speech / failed)
    /// consumes the flag; intermediate ones ("Transcribing…") don't. The reveal is held so the
    /// spinner stays visible ≥1 s — a "no speech" outcome lands in ~0.3 s, and a click that shows
    /// nothing reads as a dead button (user report). The row then flashes the outcome in place.
    private func pushFlushOutcomeIfNeeded(_ status: String) {
        guard notifyWhenTranscribed, let o = flushOutcome(for: status) else { return }
        notifyWhenTranscribed = false
        let file = status.hasPrefix("Saved: ") ? lastTranscriptURL?.path : nil
        let gen = flushGeneration
        let hold = spinnerHold(elapsed: ProcessInfo.processInfo.systemUptime - spinStartedAt)
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard let self, self.flushGeneration == gen else { return }
            self.hideFlushSpinner()
            self.flashTranscribeRow(o.title)   // in-menu answer, e.g. "No speech found"
            Notifier.push(title: o.title, body: o.body, filePath: file)
        }
    }

    /// Menu-item look for the Transcribe-now row (borderless buttons default to the gray button
    /// style), flipping to white while the hover pill shows — and rendering whatever the current
    /// row title is, so a flashed outcome survives hover changes.
    private func styleTranscribeRow() {
        let fg: NSColor = rowHovered ? .selectedMenuItemTextColor : .labelColor
        transcribeBtn.attributedTitle = NSAttributedString(
            string: transcribeRowTitle,
            attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: fg])
        transcribeBtn.contentTintColor = fg
    }

    /// Show the flush outcome in the row itself for a moment ("No speech found"), then restore
    /// "Transcribe now" — the menu stays open on click, so the answer belongs where the user is looking.
    private func flashTranscribeRow(_ text: String) {
        transcribeRowTitle = text
        styleTranscribeRow()
        let gen = flushGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.flushGeneration == gen else { return }   // a newer flush owns the row
            self.transcribeRowTitle = "Transcribe now"
            self.styleTranscribeRow()
        }
    }

    /// While a manual flush transcribes, the ROW shows the progress: its icon slot becomes a small
    /// spinner. The tray glyph stays put — a changing menu-bar icon read as noise (user pick).
    private func showFlushSpinner() {
        guard !flushBusy else { return }
        flushBusy = true
        flushGeneration += 1
        spinStartedAt = ProcessInfo.processInfo.systemUptime
        // A transparent placeholder the SAME SIZE as the icon: with image=nil the title slides left
        // into the icon slot and renders UNDER the spinner (user report: "UI broke while spinning").
        let iconSize = transcribeBtn.image?.size ?? NSSize(width: 16, height: 16)
        transcribeBtn.image = NSImage(size: iconSize)     // no representations = draws nothing
        transcribeBtn.isEnabled = false           // no double-flush while one is running
        menuRowSpinner.startAnimation(nil)
        // Failsafe: whisper on a long segment takes minutes, but a lost outcome (engine swapped out
        // mid-flush) must not leave the row spinning forever.
        let gen = flushGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 15 * 60) { [weak self] in
            guard let self, self.flushBusy, self.flushGeneration == gen else { return }
            elog("menu: flush spinner timed out — restoring the row")
            self.hideFlushSpinner()
        }
    }

    private func hideFlushSpinner() {
        guard flushBusy else { return }
        flushBusy = false
        menuRowSpinner.stopAnimation(nil)
        transcribeBtn.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "Transcribe now")
        transcribeBtn.isEnabled = true
    }

    @objc private func togglePause() {
        // A manual choice beats BOTH gates until the next schedule boundary — stored as the boundary's
        // TIMESTAMP so it still expires when the Mac slept across it. With no schedule boundary (calendar-
        // only gating) it holds until the user acts again (distantFuture), not nil — else Resume during a
        // "no meeting" pause self-reverts on the next tick.
        scheduleOverrideUntil = overrideExpiry(RecordSchedule.fromPrefs, now: Date())
        // Resume covers BOTH states WE own: a manual pause and a schedule-parked (off-hours) engine.
        // The bug: schedule-pause (paused == false) fell through to the else and manually PAUSED
        // instead of resuming. Same decision the label/enablement use — capture before clearing.
        let wasStopped = togglePauseShouldResume(paused: paused, schedulePaused: schedulePaused)
        schedulePaused = false
        if wasStopped {
            paused = false; refresh("Resuming…")
            resumeEngineAfterStop()
        } else {
            paused = true; setIcon(recording: false); refresh("⏸ Paused")
            if let eng = engine {
                engine = nil
                let starting = startTask
                stopTask = Task { if let starting { _ = await starting.value }; await eng.stop() }
            }
        }
    }

    /// Start the engine once any in-flight stop has finished (see togglePause for why waiting matters).
    private func resumeEngineAfterStop() {
        // Pause's stop is fire-and-forget (instant UI); a quick resume must WAIT for it, or two
        // capture pipelines briefly overlap (two mic queues + two taps on the shared audio state).
        // stopTask stays set until the stop has truly finished — clearing it on read would let a
        // pause→resume→pause→resume flurry start an engine while the first stop is still in flight.
        let stopping = stopTask
        Task {
            if let stopping { _ = await stopping.value }
            await MainActor.run {
                if self.stopTask == stopping { self.stopTask = nil }
                if !self.paused && !self.schedulePaused && self.engine == nil { self.startEngine() }
            }
        }
    }

    /// L3 of the pipeline: the digest logic lives in DigestCoordinator (extracted so the tick wiring —
    /// where the 453-retry storm actually lived — is scenario-testable with a virtual clock).
    private func maybeRunDailyDigest() { digestCoordinator.tick() }

    /// Enforce the recording schedule (~30 s tick). A manual Pause/Resume overrides until the next
    /// schedule boundary — an expiry TIMESTAMP, so it lapses even if the Mac slept across it.
    /// The recording-window pause reason RIGHT NOW (schedule ∩ calendar-gate), or nil to record. Read
    /// live each call so a saved setting takes effect without a restart. `overriding` = a manual
    /// Pause/Resume override is in force, which records regardless of both gates until it expires.
    private func recordingWindowPauseNow(overriding: Bool, now: Date) -> RecordPause? {
        if overriding { return nil }
        let sched = RecordSchedule.fromPrefs
        let gated = Pref.bool(Pref.calGated, "MR_CALENDAR_GATE", false)
        let pad = Pref.int(Pref.calGatePad, "MR_CALENDAR_GATE_PAD", 5)
        return recordingWindowState(scheduleEnabled: sched.enabled, scheduleActive: sched.isActive(at: now),
                                    calendarGated: gated, calendarAuthorized: CalendarLookup.authorized,
                                    meetingActive: gated ? CalendarLookup.meetingLiveNow(padMinutes: pad) : false)
    }

    private func pauseMessage(_ p: RecordPause) -> String {
        switch p {
        case .offHours: return "⏸ Off-hours (schedule)"
        case .noMeeting: return "⏸ No meeting (calendar)"
        }
    }

    private func checkSchedule() {
        let now = Date()
        if let until = scheduleOverrideUntil, now >= until { scheduleOverrideUntil = nil }
        let pause = recordingWindowPauseNow(overriding: scheduleOverrideUntil != nil, now: now)
        if pause == nil {
            if schedulePaused {   // the recording window re-opened (schedule/calendar/override) while held
                schedulePaused = false; schedulePauseReason = nil
                if !paused { elog("engine: recording window reopened"); refresh("Resuming…"); resumeEngineAfterStop() }
            }
            return
        }
        if !paused, !schedulePaused, engine != nil {   // window closed while recording → park the engine
            schedulePaused = true
            setIcon(recording: false)
            if let eng = engine {
                engine = nil
                let starting = startTask
                stopTask = Task { if let starting { _ = await starting.value }; await eng.stop() }
            }
        }
        if schedulePaused, schedulePauseReason != pause {   // reflect the CURRENT reason (schedule↔calendar)
            schedulePauseReason = pause
            refresh(pauseMessage(pause!))
            elog("engine: parked — \(pauseReason(pause!))")
        }
    }

    /// Toggle the real-time caption overlay (macOS 26+ SpeechAnalyzer). The saved whisper transcript
    /// is unaffected — this is a live view only.
    @available(macOS 26, *)
    @objc private func toggleLive() {
        LiveCaptions.shared.toggle()
        liveItem?.state = LiveCaptions.shared.active ? .on : .off
    }

    /// Fire the permission prompts inline. System Audio Recording, Microphone and Calendar all show
    /// a normal consent popup on macOS 15+ (kTCCServiceAudioCapture prompts like the mic does), so no
    /// Settings trip is needed for a first grant. If audio is still denied afterwards (user clicked
    /// Deny earlier → no re-prompt), deep-link to the Privacy pane so they can toggle it.
    @objc private func grantPermissions() {
        NSApp.activate(ignoringOtherApps: true)
        _ = requestPermissions()          // System Audio Recording prompt + Microphone popup
        CalendarLookup.requestAccess()    // Calendar popup
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // Whichever grant is still missing after the prompt — audio (fatal) first, else mic. The OS
            // won't re-prompt a denial, so a denied user needs the System Settings pane, not a no-op.
            guard let pane = permissionDeepLinkPane(audioOK: audioCaptureAuthorized(), micOK: micAuthorized()),
                  let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
            NSWorkspace.shared.open(u)
        }
    }

    @objc private func openSettings() {
        if settingsWC == nil { settingsWC = SettingsWindowController(onSave: { [weak self] in self?.restartEngine() }) }
        settingsWC?.showWindow(nil)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func restartEngine() {
        refresh("Applying settings…")
        setupModelDownload()   // a newly-selected model starts downloading (if not already present)
        let old = engine; engine = nil; paused = false
        schedulePaused = false; schedulePauseReason = nil; scheduleOverrideUntil = nil   // Save re-baselines
        let pending = stopTask   // settings saved while paused → that stop may still be in flight; kept set
        let starting = startTask // until done so an interleaved resume can't slip past it (see togglePause)
        Task {
            if let starting { _ = await starting.value }
            if let pending { _ = await pending.value }
            if let old = old { await old.stop() }
            await MainActor.run {
                if self.stopTask == pending { self.stopTask = nil }
                self.startEngineRespectingSchedule()   // a just-edited schedule applies NOW, without
            }                                          // the start-then-stop race of a blind start
        }
    }

    /// Clicking the app icon in /Applications/Launchpad/Dock while it's running → the windowed app
    /// (the Library), not just the tray menu — a real app comes forward when reopened.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openLibrary(); return true
    }

    /// ⌘Q while any app window is up CLOSES that window (back to the menu-bar agent) — a windowed
    /// reflex must never kill 24/7 recording. The tray Quit, SIGTERM, and a logout/shutdown-reasoned
    /// quit event really quit (cancelling logout would BLOCK it — worse than any lost window).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let ev = NSAppleEventManager.shared().currentAppleEvent,
           ev.eventClass == AEEventClass(kCoreEventClass), ev.eventID == AEEventID(kAEQuitApplication),
           ev.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil {
            realQuitRequested = true   // logout / restart / shutdown carries a quit reason
        }
        // Titled windows only: the status-item window and the borderless caption overlay are always
        // "visible" and would otherwise swallow every quit forever.
        let windowUp = NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) }
        if terminateShouldJustCloseWindow(realQuit: realQuitRequested, windowVisible: windowUp != nil) {
            (NSApp.keyWindow?.styleMask.contains(.titled) == true ? NSApp.keyWindow : windowUp)?
                .performClose(nil)
            return .terminateCancel
        }
        return .terminateNow
    }

    /// Open the tray menu programmatically (when the app is clicked in /Applications).
    @objc private func openMenu() {
        NSApp.activate(ignoringOtherApps: true)
        statusItem.button?.performClick(nil)
    }

    @objc private func openTranscripts() {
        let dir = EngineConfig.load().transcriptsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func showLog() { LogWindow.shared.show() }

    /// A hidden main menu carrying only the standard Edit shortcuts. A menu-bar (accessory) app shows no
    /// menu bar, so ⌘X/C/V/A/Z reach a focused text field or text view ONLY if the main menu defines them.
    /// Items target the first responder (nil action target), so AppKit validates + routes them to whatever
    /// text control has focus — the log filter and log view, Settings fields, the caption window.
    static func editShortcutMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        // ⌘Q routes through the delegate's terminate reply — window-close, not app-death.
        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "File"); fileItem.submenu = file
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return main
    }

    /// Manual check (menu): ALWAYS gives visible in-app feedback — an alert for up-to-date / newer /
    /// failure — not only a notification (which the user may have silenced, so the menu looked dead).
    @objc private func checkForUpdates() {
        guard !checkingForUpdates else { return }   // one modal at a time — a re-click must not stack alerts
        checkingForUpdates = true
        UpdateChecker.fetchLatest { [weak self] tag, url in   // fetchLatest already calls back on the main queue
            guard let self else { return }
            self.checkingForUpdates = false
            guard let tag else {
                self.showUpdateAlert(title: "Update check failed",
                                     text: "Couldn't reach GitHub. Check your connection and try again.", style: .warning)
                return
            }
            if isNewerVersion(tag, than: macrecVersion) {
                let openURL = updateAlertOpenURL(installedViaBrew: UpdateChecker.installedViaBrew,
                                                 htmlURL: url, releasesURL: UpdateChecker.releasesURL)
                self.showUpdateAlert(title: "macrec \(tag) is available",
                                     text: UpdateChecker.installedViaBrew ? "Run `brew upgrade --cask macrec` to update."
                                                                          : "Open the release page to download it.",
                                     openURL: openURL)
            } else {
                self.showUpdateAlert(title: "You're up to date",
                                     text: "macrec v\(macrecVersion) is the latest release.")
            }
        }
    }

    /// A visible, focus-stealing result for a user-initiated update check. macrec is `.accessory`, so
    /// activate first or the alert can open behind everything (the "no reaction" the user saw). With an
    /// `openURL` it offers Open (default/Return) + Cancel (Esc); otherwise a lone OK.
    private func showUpdateAlert(title: String, text: String, openURL: URL? = nil, style: NSAlert.Style = .informational) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.alertStyle = style
        if openURL != nil {
            a.addButton(withTitle: "Open")                              // first button = default, bound to Return
            a.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"   // Esc dismisses without opening a browser
        }
        let resp = a.runModal()
        if let openURL, resp == .alertFirstButtonReturn { NSWorkspace.shared.open(openURL) }
    }

    /// Background daily check — rides the 30 s tick with a last-run marker (same catch-up-after-
    /// sleep semantics as the daily digest). Silent unless something new is actually out.
    private func maybeCheckForUpdates() {
        guard Pref.bool(Pref.autoUpdateCheck, "MR_AUTO_UPDATE_CHECK", true) else { return }
        let dayF = DateFormatter(); dayF.locale = Locale(identifier: "en_US_POSIX"); dayF.dateFormat = "yyyy-MM-dd"
        let today = dayF.string(from: Date())
        guard Pref.explicit(Pref.updateCheckLastRun, "") != today else { return }
        Pref.d.set(today, forKey: Pref.updateCheckLastRun)
        UpdateChecker.fetchLatest { [weak self] tag, url in
            guard let tag, isNewerVersion(tag, than: macrecVersion) else { return }
            self?.announceUpdate(tag: tag, url: url)
        }
    }

    private func announceUpdate(tag: String, url: String?) {
        // Sanitize the click target through the SAME https-only gate the manual alert uses (nil for
        // brew → no click target) — the notification path must not open a file:/custom-scheme URL either.
        let open = updateAlertOpenURL(installedViaBrew: UpdateChecker.installedViaBrew,
                                      htmlURL: url, releasesURL: UpdateChecker.releasesURL)
        let how = UpdateChecker.installedViaBrew ? "Run: brew upgrade --cask macrec"
                                                 : "Click to open the release page."
        elog("update: \(tag) available (current v\(macrecVersion))")
        Notifier.push(title: "macrec \(tag) is available", body: how, openURL: open)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let credits = NSAttributedString(
            string: "Always-on meeting recorder",
            attributes: [.font: NSFont.systemFont(ofSize: 13), .paragraphStyle: para])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "macrec",
            .applicationVersion: macrecVersion,
            .credits: credits,
        ])
    }

    /// Stop the engine (→ destroys the Core Audio process tap + aggregate device) synchronously, once.
    /// A leaked tap can wedge coreaudiod ("no sound until killall coreaudiod"), so run it on EVERY
    /// termination path: menu Quit, SIGTERM/kickstart, and logout/shutdown (applicationWillTerminate).
    private func stopEngineSync() {
        guard let eng = engine else { return }
        engine = nil   // idempotent — later callers see nil and skip (no double-stop)
        let s = DispatchSemaphore(value: 0)
        Task { await eng.stop(); s.signal() }
        _ = s.wait(timeout: .now() + 15)
    }

    func applicationWillTerminate(_ notification: Notification) { stopEngineSync() }

    // Only the explicit menu Quit is a "the user chose to stop" event — NOT applicationWillTerminate
    // (which also fires on logout / SIGTERM / bootout, the very deaths #27 must surface). So the
    // forgiving clean-stop marker is written here alone.
    @objc private func quit() {
        realQuitRequested = true
        RecorderHeartbeat.noteUserQuit()
        Pref.d.set(true, forKey: Pref.watchdogQuitRequested)   // #36b: deliberate Quit — the watchdog leaves it dead
        Pref.d.synchronize()   // flush to cfprefsd BEFORE we die, so the watchdog daemon reads the flag, not a stale false
        stopEngineSync()
        NSApp.terminate(nil)
    }

    /// #27: at launch, if the prior run's heartbeat shows the PROCESS was dead for a real stretch while
    /// the mac was awake (not a reboot, not a deliberate Quit), surface it — the silent 18-hour outage
    /// that dropped a morning meeting must never be invisible again. Loud = log + notification + a
    /// durable Today row / menu line (persisted by checkOutageOnStart); shorter gaps are logged only.
    private func checkRecorderOutage() {
        if let secs = RecorderHeartbeat.checkOutageOnStart() {
            let now = Date(), from = now.addingTimeInterval(-secs)
            let window = outageWindowText(from: from, to: now)
            elog("app: recorder was DOWN ~\(humanDuration(secs)) (\(window)) — a meeting in that window may not have been captured")
            Notifier.push(title: "macrec wasn't recording",
                          body: "Down ~\(humanDuration(secs)) (\(window)). A meeting in that window may not have been captured.",
                          openWindow: "log")
        } else if RecorderHeartbeat.outageForToday() > 0 {
            // A same-day outage carried over from an earlier process (this run restarted) still shows in
            // the menu line / Today row via the persisted seconds — re-emit the detail so the log those
            // surfaces point to isn't empty in this fresh process (LogBuffer is in-memory, per-launch).
            elog("app: recorder was down ~\(humanDuration(RecorderHeartbeat.outageForToday())) earlier today — a meeting in that window may not have been captured")
        }
    }
}

extension AppController: UNUserNotificationCenterDelegate {
    /// Menu-bar agents count as "foreground", which by default swallows banners — show them anyway.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Clicking a "Transcript ready" push opens the saved file.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        // Web links ride under "url" (https-only — sanitized at push time, re-checked here); local
        // transcript paths ride under "file". Keeping them distinct means a URL is never opened as a
        // file path, nor a path as a URL (the old shared "file" key + hasPrefix("http") did both).
        if let w = info["open"] as? String {   // an in-app window (the #27 outage alert opens the log)
            switch w {
            case "today": openToday()
            case "library": openLibrary()
            default: showLog()
            }
        } else if let s = info["url"] as? String, let u = URL(string: s), u.scheme?.lowercased() == "https" {
            NSWorkspace.shared.open(u)
        } else if let p = info["file"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
        }
        completionHandler()
    }
}

var appController: AppController?   // retained for process lifetime

func runMenuBarApp() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)   // ALWAYS in the Dock (user ask) — the tray stays as the quick surface
    applySavedAppearance()              // the saved Light/Dark override must survive a relaunch
    let c = AppController()
    appController = c
    app.delegate = c
    app.run()
    exit(0)
}

/// Install a one-shot stop handler for SIGINT/SIGTERM. Returns the source (keep it alive).
func installStopHandler(_ handler: @escaping () -> Void) {
    let q = DispatchQueue(label: "macrec.stop-signal")
    for s in [SIGINT, SIGTERM] {
        signal(s, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: s, queue: q)
        src.setEventHandler(handler: handler)
        src.resume()
        signalSources.append(src)
    }
}

// MARK: - main

/// Single source of truth for the version — a compile-time constant so `macrec version` reports
/// correctly even when run via the Homebrew `bin/macrec` symlink (where Bundle.main resolves to
/// /opt/homebrew/bin, not the .app, so the Info.plist can't be read). install.sh / package.sh
/// stamp CFBundleShortVersionString from THIS value, so the binary and the bundle never drift.
let macrecVersion = "0.5.0"
