import AppKit
import AVFoundation
import Foundation

// MARK: - diagnostic / test-kit subcommands (bodies moved verbatim out of App.main)

// App.main had grown into a 300-line switchboard with every subcommand inlined; each body now
// lives here as a Never-returning function and main stays a thin dispatcher. Behavior-preserving
// moves (headers became /// docs and the formatter reflowed whitespace — the executable tokens,
// indexing and exit codes are unchanged); semantic drift in this file's history is a review flag.

/// tap-probe [seconds] — QA/diagnostic: start ONLY the system-audio tap and report whether its
/// IOProc delivers anything — built for the day capture went silent and nothing in the logs could
/// say WHERE the audio path died. The aggregate delivers NOTHING while no tapped process renders
/// audio (measured 2026-07-15: 2 s probe in silence → 0 buffers; the same probe with a sound
/// playing → 369 buffers), so the probe plays its own test tone — via CHILD afplay processes,
/// because the tap always excludes our own pid. See tapProbeVerdict for the outcomes.
func runTapProbeSubcommand(_ args: [String]) -> Never {
    if args.count > 1, Double(args[1]) == nil {
        print("tap-probe: ignoring non-numeric duration '\(args[1])' — using 6s")
    }
    let secs = max(args.count > 1 ? (Double(args[1]) ?? 6) : 6, 1)   // <1 s can't even play the tone
    let lock = NSLock()
    var buffers = 0
    var peak: Float = 0
    let tap = SystemAudioTap(excludeBundleIds: []) { buf in
        lock.lock(); defer { lock.unlock() }
        buffers += 1
        if let ch = buf.floatChannelData?[0] {
            for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(ch[i])) }
        }
    }
    do { try tap.start() } catch { print("tap-probe: start failed — \(error)"); exit(1) }
    var tonePlayed = false
    var toneErrorShown = false
    let deadline = Date().addingTimeInterval(secs)
    while true {
        let remaining = deadline.timeIntervalSinceNow
        if remaining < 0.2 { break }
        let play = Process()
        play.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        // -v 0.3: loud enough for the tap (captured peak ~0.1 ≫ the 0.001 silence bar), quiet
        // enough not to blast a sonar ping at whoever is next to a live call.
        play.arguments = ["-v", "0.3", "-t", String(format: "%.1f", min(remaining, 1.5)),
                          "/System/Library/Sounds/Submarine.aiff"]
        let began = Date()
        do { try play.run() } catch {
            print("tap-probe: could not launch afplay — \(error)")   // a diagnostic must diagnose itself
            break
        }
        // Watchdog: a wedged afplay must not hang the probe — the audio stack is exactly what
        // this tool exists to diagnose, so assume the worst of it.
        let killer = DispatchWorkItem { if play.isRunning { play.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + min(remaining, 1.5) + 2.0, execute: killer)
        play.waitUntilExit()
        killer.cancel()
        if play.terminationStatus == 0, Date().timeIntervalSince(began) >= 0.3 {
            tonePlayed = true
        } else {
            if !toneErrorShown {   // first failure: say WHY the tone isn't playing, once
                toneErrorShown = true
                print("tap-probe: afplay exited \(play.terminationStatus) after "
                    + String(format: "%.2fs", Date().timeIntervalSince(began)))
            }
            Thread.sleep(forTimeInterval: 0.3)   // afplay unusable — report it, don't spin
        }
    }
    tap.stop()
    lock.lock(); let b = buffers, p = peak; lock.unlock()
    let v = tapProbeVerdict(buffers: b, peak: p, tonePlayed: tonePlayed)
    print(String(format: "tap-probe: %.1fs — buffers=%d peak=%.4f tone=%@ → %@",
                 secs, b, p, tonePlayed ? "played" : "UNPLAYABLE", v.line))
    exit(v.code)
}

/// sweep — run one retention/archive pass now (WAV→AAC tiers + expiry) and exit. The tray app
/// does this on start and after each segment; this is for manual runs and the integration smoke
/// test. Saved Settings BEAT env vars everywhere in this app, so the flags exist to aim a one-off
/// sweep at an explicit layout without touching the real library.
func runSweepSubcommand(_ args: [String]) -> Never {
    var cfg = EngineConfig.load()
    var it = args.dropFirst().makeIterator()
    // A malformed value must ABORT, not silently proceed with saved settings — this command
    // irreversibly compresses/deletes whatever library the resolved config points at.
    func value(_ flag: String) -> String {
        guard let v = it.next() else { print("sweep: \(flag) needs a value"); exit(2) }
        return v
    }
    func intValue(_ flag: String) -> Int {
        let v = value(flag)
        guard let n = Int(v), n >= 0 else { print("sweep: \(flag) needs a non-negative integer, got '\(v)'"); exit(2) }
        return n
    }
    while let a = it.next() {
        switch a {
        case "--audio-dir": cfg.audioDir = URL(fileURLWithPath: value(a))
        case "--transcripts-dir": cfg.transcriptsDir = URL(fileURLWithPath: value(a))
        case "--raw-days": cfg.audioRawDays = intValue(a)
        case "--keep-days": cfg.audioRetentionDays = intValue(a)
        default: print("unknown sweep option: \(a) (see: help)"); exit(2)
        }
    }
    RecordingEngine(cfg: cfg).runRetentionSweep()
    exit(0)
}

/// settings-snapshot <dir> — render every Settings pane to a PNG and exit.
/// The UI test kit: LOOK at what was built. Needs a GUI session (run locally, not in CI).
@MainActor
func runSettingsSnapshotSubcommand(_ args: [String]) -> Never {
    let dir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/tmp/macrec-settings-shots")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let wc = SettingsWindowController(onSave: {})
    let files = wc.snapshotAllPanes(to: dir)
    for f in files { print(f.path) }
    print(files.isEmpty ? "snapshot: FAILED (no panes rendered)" : "snapshot: \(files.count) panes → \(dir.path)")
    exit(files.isEmpty ? 1 : 0)
}

/// library-snapshot <dir> — render the Library window over FIXTURE data to a PNG. Fixture-only on
/// purpose: a snapshot must never leak real meeting names, and the harness must not read the
/// user's vault.
@MainActor
func runLibrarySnapshotSubcommand(_ args: [String]) -> Never {
    let dir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/tmp/macrec-library-shots")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // The fixture entries all point at these files — give the preview pane something to
    // show that exercises the whole markdown subset, and a real (generated) wav so the
    // player bar proves its wiring with an actual duration.
    let fixtureMD = """
    # project kickoff

    > Auto-transcribed fixture (speakers: Me = microphone, Them = system audio).

    - Time: 2026-03-02 14:00–15:00 (60 min)
    - Audio: [recording](library-fixture.wav) · Model: `ggml-fixture.bin`
    - Docs: https://example.com/kickoff-notes

    ## Decisions

    1. Ship **increment one** first, polish later.
    2. Keep the tray menu; the desktop window is additive.
       - nested detail line

    ## Action items

    - [ ] draft the rollout plan — alex
    - [x] book the follow-up — sam

    | Owner | Item | Due |
    |---|---|---|
    | alex | rollout plan | Fri |
    | sam | follow-up | done |

    ## Transcript

    [14:01:12] Me: 킥오프 시작하겠습니다.
    [14:01:30] Them: *좋습니다* — 아젠다부터 볼까요?

    ```
    raw block: -::~:~:: pasted calendar art must stay verbatim ::~:~::-
    ```
    """
    try? fixtureMD.write(toFile: "/tmp/library-fixture.md", atomically: true, encoding: .utf8)
    if let w = try? SourceWriter(url: URL(fileURLWithPath: "/tmp/library-fixture.wav")),
       let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
       let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16000) {
        buf.frameLength = 16000
        for i in 0..<16000 { buf.floatChannelData![0][i] = sinf(Float(i) * 0.13) * 0.2 }
        w.append(buf)   // 1 s tone → the clock should read 0:00 / 0:01
    }
    // Built-in summary mode (in the throwaway test store): the Re-run summary button must
    // be laid out in the shot — hidden-by-prefs would leave the new control unseen forever.
    Pref.d.set("summary", forKey: Pref.postProcessMode)
    LibraryWindow.shared.loadFixtureForTest(libraryFixtureDays())
    LibraryWindow.shared.primePlayerForTest()
    // Show the TRANSCRIPT view (not the default summary): the stamped lines render their
    // macrec-seek links there, and the PNG must show them.
    LibraryWindow.shared.pickDocForTest(1)
    // BOTH appearances (dark and light must each be looked at); a missing mode FAILS — partial
    // output would read as "covered both" when it didn't. Daily-scope shots ride the same loop.
    var files: [URL] = []
    var missing = false
    for (mode, name) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
        NSApp.appearance = NSAppearance(named: name)
        let main = LibraryWindow.shared.snapshot(to: dir.appendingPathComponent(mode))
        LibraryWindow.shared.setScopeForTest(1)
        let daily = LibraryWindow.shared.snapshot(to: dir.appendingPathComponent(mode).appendingPathComponent("daily"))
        LibraryWindow.shared.setScopeForTest(0)
        // The Daily scope filtered the selected transcript out and CLEARED the selection — restore
        // it, or every later shot (the other appearance) renders an empty detail pane.
        LibraryWindow.shared.loadFixtureForTest(libraryFixtureDays())
        LibraryWindow.shared.pickDocForTest(1)
        if main.isEmpty || daily.isEmpty { missing = true }
        files += main + daily
    }
    if missing { print("library-snapshot: FAILED (a mode's shot is missing)"); exit(1) }
    for f in files { print(f.path) }
    print(files.isEmpty ? "library-snapshot: FAILED (nothing rendered)" : "library-snapshot: \(files.count) shots → \(dir.path)")
    exit(files.isEmpty ? 1 : 0)
}

/// today-snapshot <dir> — render the Today dashboard over FIXTURE health rows (a mix of ok/warn/bad
/// so the PNG shows every level and every action button). No live app read.
@MainActor
func runTodaySnapshotSubcommand(_ args: [String]) -> Never {
    let dir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/tmp/macrec-today-shots")
    NSApplication.shared.setActivationPolicy(.accessory)
    var i = HealthInputs()
    i.audioGranted = true; i.micGranted = true; i.calendarGranted = false   // one warn
    i.recording = true; i.captureTest = .silent            // one bad (confirmed muted tap)
    i.micLevel = 0.4; i.sysLevel = 0
    i.modelReady = true; i.modelName = "large-v3"; i.whisperResolved = true
    i.runnerResolved = true; i.runnerName = "claude"
    i.summary = .failed("2026-07-19-1400.md", i.now, reason: "Not logged in")   // one bad + Retry
    i.transcriptsToday = 3; i.summariesToday = 2
    i.digestEnabled = true; i.digestTime = "20:00"
    i.notificationsDenied = true   // #33: exercise the "Notifications off" warn row + its Settings… button
    i.capturedSilenceToday = true  // dropped-metric: exercise the "Recorded silence earlier" warn row
    TodayWindow.shared.loadFixtureForTest(todayHealth(i))
    // BOTH appearances; a missing mode FAILS rather than passing on partial output.
    var files: [URL] = []
    for (mode, name) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
        NSApp.appearance = NSAppearance(named: name)
        let shots = TodayWindow.shared.snapshot(to: dir.appendingPathComponent(mode))
        if shots.isEmpty { print("today-snapshot: FAILED (\(mode) shot missing)"); exit(1) }
        files += shots
    }
    for f in files { print(f.path) }
    print(files.isEmpty ? "today-snapshot: FAILED (nothing rendered)" : "today-snapshot: \(files.count) shot → \(dir.path)")
    exit(files.isEmpty ? 1 : 0)
}

/// caption-snapshot — render the live overlay at several opacities over a checkerboard.
/// The one thing to LOOK for: the background fades, the captions never do.
@MainActor
func runCaptionSnapshotSubcommand(_ args: [String]) -> Never {
    let dir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/tmp/macrec-caption-shots")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard #available(macOS 26, *) else { print("caption-snapshot: needs macOS 26"); exit(1) }
    // Both presentations, at both extremes: the log view and the subtitle view have different
    // failure modes, and the transparent end is the one that used to hide the captions entirely.
    // Writing the pref is safe — Pref.d is a throwaway suite under any test subcommand.
    var files: [URL] = []
    for subtitle in [false, true] {
        Pref.d.set(subtitle, forKey: Pref.liveSubtitle)
        let w = LiveCaptionWindow(onClose: {}, onReconfigure: {}, onRestyle: {})
        let sub = dir.appendingPathComponent(subtitle ? "subtitle" : "log")
        files += w.snapshotOpacities([1.0, 0.6, 0.0], to: sub)
    }
    for f in files { print(f.path) }
    if files.isEmpty {
        print("caption-snapshot: FAILED — the overlay rendered to nothing, so no PNG was written. "
            + "Something in the panel is composited by the window server again (a vibrancy material, "
            + "or the .hudWindow style mask); an offscreen render cannot see those.")
    } else {
        print("caption-snapshot: \(files.count) shots → \(dir.path)")
    }
    exit(files.isEmpty ? 1 : 0)
}

/// icon-snapshot — render the menu-bar brand mark's states to PNGs on a gray backdrop (the tray
/// icon has no other snapshot; UI test kit per CLAUDE.md). LOOK at these after any change.
@MainActor
func runIconSnapshotSubcommand(_ args: [String]) -> Never {
    let dir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/tmp/macrec-icon-shots")
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.accessory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let states: [(String, Bool, Bool)] = [("recording-voice", true, true), ("recording-quiet", true, false), ("paused", false, false)]
    let side: CGFloat = 18, scale = 10, pad: CGFloat = 6
    var wrote = 0
    for (name, rec, voice) in states {
        let mark = brandMarkImage(side: side, recording: rec, voice: voice)
        let w = mark.size.width + pad * 2, h = mark.size.height + pad * 2   // fit the glyph's natural aspect
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w) * scale, pixelsHigh: Int(h) * scale,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.16, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()   // menu-bar-ish backdrop
        mark.draw(in: NSRect(x: pad, y: pad, width: mark.size.width, height: mark.size.height))
        NSGraphicsContext.restoreGraphicsState()
        if let png = rep.representation(using: .png, properties: [:]) {
            let u = dir.appendingPathComponent("icon-\(name).png"); try? png.write(to: u); print(u.path); wrote += 1
        }
    }
    print(wrote == 0 ? "icon-snapshot: FAILED" : "icon-snapshot: \(wrote) states → \(dir.path)")
    exit(wrote == 0 ? 1 : 0)
}
