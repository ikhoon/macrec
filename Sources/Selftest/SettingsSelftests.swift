import AppKit
import AVFoundation
import EventKit
import Foundation

func settingsSelftests(_ check: (String, Bool) -> Void) {
    // Settings layout regression (user-reported): a tab taller than the window CLIPPED its rows
    // (Post-process settings were unreachable). Every pane must host its grid in a scroll view,
    // and Post-process must be its own tab. Headless: builds the real form, no window shown.
    let sw = SettingsWindowController(onSave: {})
    let panes = sw.panesForTest
    check("settings: panes built for inspection", !panes.isEmpty)
    check("settings: General pane comes first", panes.first?.title == "General")
    // AUTOMATED UI TEST: lay out every pane at a real size and assert nothing is collapsed
    // or overlapping. This fails the build on visual breakage (the NSBox "card" redesign
    // floated its grids so controls overlapped and shipped destroyed — a structural-only
    // check passed it). Run `macrec settings-snapshot <dir>` to also eyeball the PNGs.
    let layoutIssues = sw.paneLayoutIssues()
    if !layoutIssues.isEmpty { for m in layoutIssues.prefix(8) { print("   layout: \(m)") } }
    check("settings: no pane control is collapsed or overlapping (\(layoutIssues.count) issues)",
          layoutIssues.isEmpty)
    check("settings: every pane scrolls (rows can never be clipped away)",
          panes.allSatisfy { p in p.view.subviews.contains { ($0 as? NSScrollView)?.documentView != nil } })
    check("settings: Summaries and Schedule are their own panes",
          panes.contains { $0.title == "Summaries" } && panes.contains { $0.title == "Schedule" })
    check("settings: Recording split into Recording + Storage panes",
          panes.contains { $0.title == "Recording" } && panes.contains { $0.title == "Storage" })
    // Grouped row-card structure: every pane renders at least one rounded SectionCard, and
    // no card is empty (a section with no rows would draw a stray hairline box).
    func allCards(in view: NSView) -> [SectionCard] {
        var out: [SectionCard] = []
        if let c = view as? SectionCard { out.append(c) }
        if let sv = view as? NSScrollView, let d = sv.documentView { out += allCards(in: d) }
        for sub in view.subviews { out += allCards(in: sub) }
        return out
    }
    var cardCount = 0
    var everyPaneHasCard = true
    var noEmptyCard = true
    for p in panes {
        let cards = allCards(in: p.view)
        cardCount += cards.count
        if cards.isEmpty { everyPaneHasCard = false }
        for c in cards {
            // A card wraps a single vertical stack of rows; an empty stack = a bug.
            let rows = (c.subviews.first as? NSStackView)?.arrangedSubviews ?? []
            if rows.isEmpty { noEmptyCard = false }
        }
    }
    check("settings: every pane renders at least one section card",
          cardCount >= panes.count && everyPaneHasCard)
    check("settings: no section card is empty", noEmptyCard)
    // Sidebar search: pane content (not just titles) is the index — "prompt" finds
    // Summaries, junk finds nothing, empty shows everything in order.
    check("settings: sidebar search matches pane content",
          settingsSearchHits(query: "prompt", index: panes.map { $0.searchText })
              .contains(panes.firstIndex { $0.title == "Summaries" } ?? -1)
          && settingsSearchHits(query: "", index: panes.map { $0.searchText }) == Array(panes.indices)
          && settingsSearchHits(query: "zzxqy", index: panes.map { $0.searchText }).isEmpty
          && settingsSearchHits(query: "API KEY", index: panes.map { $0.searchText })
              .contains(panes.firstIndex { $0.title == "Live Captions" } ?? -1))
    // Edit shortcuts in the Settings window (LSUIElement app has no Edit menu — ⌘V into a
    // field once did nothing, user-reported). The window routes these action selectors to
    // the field editor; the mapping is pure and checked here.
    check("settings: ⌘V/⌘C/⌘X/⌘A map to the standard edit actions",
          standardEditSelector(key: "v", flags: .command) == #selector(NSText.paste(_:))
          && standardEditSelector(key: "c", flags: .command) == #selector(NSText.copy(_:))
          && standardEditSelector(key: "x", flags: .command) == #selector(NSText.cut(_:))
          && standardEditSelector(key: "a", flags: .command) == #selector(NSResponder.selectAll(_:)))
    check("settings: ⌘Z undo, ⌘⇧Z redo, plain V ignored, ⌘⌥V not hijacked",
          standardEditSelector(key: "z", flags: .command) == Selector(("undo:"))
          && standardEditSelector(key: "z", flags: [.command, .shift]) == Selector(("redo:"))
          && standardEditSelector(key: "v", flags: []) == nil
          && standardEditSelector(key: "v", flags: [.command, .option]) == nil)
    // Schedule pickers (days multi-select + time-range rows) must round-trip through the SAME
    // string prefs the engine parses — seed the UI, read it back, and confirm it parses to the
    // identical RecordSchedule (no meaning lost when we swapped text fields for pickers).
    sw.loadScheduleUI(days: "mon,wed,fri", hours: "10:00-12:00, 13:00-19:00")
    let rtDays = sw.serializeDays(), rtHours = sw.serializeHours()
    check("settings: schedule pickers round-trip to the engine's format",
          RecordSchedule.parseDays(rtDays) == RecordSchedule.parseDays("mon,wed,fri")
          && RecordSchedule.parseRanges(rtHours).map { [$0.start, $0.end] }
             == RecordSchedule.parseRanges("10:00-12:00, 13:00-19:00").map { [$0.start, $0.end] })
    sw.loadScheduleUI(days: "", hours: "")   // empty = every day / all hours
    check("settings: empty schedule serializes empty (every day, all hours)",
          sw.serializeDays().isEmpty && sw.serializeHours().isEmpty)
    // Nested-scroll passthrough: the pane must still scroll with the pointer over a prompt box.
    // A prompt/calendar box
    // whose content FITS must hand the wheel to the pane; one that OVERFLOWS keeps it to scroll
    // itself. The prompt editor is ~84pt tall — text that fits passes through, long text doesn't.
    check("settings: nested scroll passes wheel to pane when its content fits",
          nestedScrollPassesThrough(contentHeight: 84, clipHeight: 84)          // exact fit → pass
          && nestedScrollPassesThrough(contentHeight: 40, clipHeight: 84)       // smaller → pass
          && !nestedScrollPassesThrough(contentHeight: 400, clipHeight: 84)     // overflow → keep
          && !nestedScrollPassesThrough(contentHeight: 85, clipHeight: 84))     // just over → keep
    // The embedded editors/lists are actually PassthroughScrollViews in the built tree (prompt,
    // daily-prompt, calendar) — so the fix is wired, not just declared.
    check("settings: embedded editors use the passthrough scroll view",
          sw.passthroughScrollCountForTest >= 2)
    // Tray Pause/Resume enablement: Pause greys out when nothing is recording (off-hours/idle);
    // Resume stays clickable while paused.
    check("tray: Pause enabled recording; Resume enabled when paused OR schedule-paused; greyed only when truly idle",
          pauseItemEnabled(paused: false, schedulePaused: false, hasEngine: true)       // recording → can Pause
          && !pauseItemEnabled(paused: false, schedulePaused: false, hasEngine: false)  // truly idle → greyed
          && pauseItemEnabled(paused: true, schedulePaused: false, hasEngine: false)    // manual pause → can Resume
          && pauseItemEnabled(paused: false, schedulePaused: true, hasEngine: false)    // schedule off-hours → can Resume (the fix)
          && pauseItemEnabled(paused: true, schedulePaused: true, hasEngine: true))
    // Every "Choose…" folder button is bound to a handler the controller implements — guards
    // against a picker wired to nothing / a renamed selector (user: Storage "Choose…" did nothing).
    let chooseWired = sw.chooseButtonsWiredForTest
    check("settings: every Choose… button is wired to a real handler (\(chooseWired.count) found)",
          chooseWired.count >= 7 && chooseWired.allWired)
    // An NSSwitch carries no title, so its row name has to be attached as an accessibility label
    // or VoiceOver reads an anonymous button where a named setting used to be.
    check("settings: every switch announces its setting name to VoiceOver",
          sw.unlabeledSwitchesForTest == 0)
    // The footer: "Save" (default) applies in place, "Close" (Esc) leaves. Guards the wiring —
    // a renamed selector here silently turns Save into a dead button.
    let footer = sw.footerButtonsForTest
    check("settings: footer is Close + Save, both wired (Save no longer closes the window)",
          footer.map(\.title) == ["Close", "Save"]
          && footer.allSatisfy { b in (b.target as? NSObject)?.responds(to: b.action ?? Selector("")) == true }
          && footer.last?.keyEquivalent == "\r" && footer.first?.keyEquivalent == "\u{1b}")
    // The overlay's engine picker must never offer an engine that can't run: Deepgram sat in the
    // list with no API key and answered a click with an error line where captions belong.
    // Apple is the floor — switching everything off must not leave an empty picker.
    let noKeys: (LiveEngine) -> Bool = { $0 == .apple || $0 == .whisper }
    check("live: the engine picker offers only engines that are ON and READY (never empty)",
          selectableLiveEngines(LiveEngine.allCases, ready: noKeys, enabled: { _ in true }) == [.apple, .whisper]
          && selectableLiveEngines(LiveEngine.allCases, ready: { _ in true },
                                   enabled: { $0 != .apple }) == [.whisper, .deepgram, .openai, .gladia, .elevenlabs]
          && selectableLiveEngines(LiveEngine.allCases, ready: noKeys,
                                   enabled: { $0 != .apple && $0 != .whisper }) == [.apple]
          && selectableLiveEngines(LiveEngine.allCases, ready: { _ in false }, enabled: { _ in false }) == [.apple])
    // The opacity slider fades the BACKGROUND. Fading the window faded the captions with it —
    // at 0.3 the overlay showed nothing at all, which is the one thing it exists to show.
    // Zero is a legal, useful setting — the closed-caption look. Only out-of-range values clamp.
    // Contrast goes BEHIND the glyphs, never into them: a halo smeared them, a stroke thickened
    // them. And only when the backdrop is too faint to carry the contrast itself.
    // A subtitle leads with the TRANSLATION — that is the line you read; the original is a
    // whisper above it. With nothing to translate, the original is the subtitle.
    check("live: a subtitle leads with the translation and demotes the original",
          subtitleLine(original: "会議を始めましょう。", translated: "회의를 시작합시다.")
          == ("회의를 시작합시다.", "会議を始めましょう。")
          && subtitleLine(original: "Let's begin.", translated: nil) == ("Let's begin.", nil)
          && subtitleLine(original: "Let's begin.", translated: "  ") == ("Let's begin.", nil)
          && subtitleLine(original: "", translated: "회의") == ("회의", nil))
    // Read at a glance, not squinted at; and a film shows one utterance, not a scrolling wall.
    check("live: a subtitle is larger than the log's body text and shows only the current utterance",
          subtitleFontSize(14) == 20 && subtitleFontSize(9) == 18 && subtitleMaxLines == 1)
    check("live: past log lines are dimmed, the current line stays full strength",
          captionLineAlpha(isCurrent: true) == 1.0 && captionLineAlpha(isCurrent: false) < 1.0)
    // A transparent LOG keeps an outline so it still reads as a grabbable window; a subtitle must
    // not have one — a rectangle drawn around a film subtitle is what breaks the illusion.
    check("live: the window outline is drawn for the log view and never for a subtitle",
          captionEdgeVisible(subtitle: false) && !captionEdgeVisible(subtitle: true))
    // The opacity slider fades only the window backdrop; the text keeps its own solid plate at every
    // opacity below fully-opaque, so lowering opacity never makes the text or its background transparent.
    check("live: captions carry a backplate at any opacity below fully-opaque (only a solid panel skips it)",
          captionTextNeedsBackplate(backdropAlpha: 0.0)
          && captionTextNeedsBackplate(backdropAlpha: 0.5)
          && captionTextNeedsBackplate(backdropAlpha: 0.99)
          && !captionTextNeedsBackplate(backdropAlpha: 1.0))
    // In-app Log window: the filter is a case-insensitive substring; a blank filter keeps everything.
    let logSample = ["openailive[me] connecting", "echo(speex): cumIn=1", "keychain: read failed", "ECHO loud"]
    check("log filter: case-insensitive substring, blank keeps all",
          logLinesFiltered(logSample, filter: "openai") == ["openailive[me] connecting"]
          && logLinesFiltered(logSample, filter: "ECHO").count == 2   // "echo(speex)" + "ECHO loud"
          && logLinesFiltered(logSample, filter: "  ") == logSample
          && logLinesFiltered(logSample, filter: "nomatch").isEmpty)
    // The log ring is bounded — a flood of lines (the echo canceller prints often) can't grow it forever.
    LogBuffer.clear()
    for i in 0..<(LogBuffer.cap + 500) { LogBuffer.append("line \(i)") }
    check("log buffer: bounded to its cap under a flood", LogBuffer.countForTest() == LogBuffer.cap)
    LogBuffer.clear()
    check("live: overlay opacity spans a fully transparent backdrop to a fully opaque one",
          captionBackdropAlpha(0.0) == 0.0 && captionBackdropAlpha(1.0) == 1.0
          && captionBackdropAlpha(0.3) == 0.3
          && captionBackdropAlpha(-1) == 0.0 && captionBackdropAlpha(9.9) == 1.0)
    // Drive the real window: at the slider's low end ONLY the backdrop may be translucent.
    // Window alpha would multiply into every subview, which is exactly how the captions vanished.
    if #available(macOS 26, *) {
        let cw = LiveCaptionWindow(onClose: {}, onReconfigure: {}, onRestyle: {})
        let before = cw.captionAlphasForTest
        cw.setOpacityForTest(0.0)   // the extreme: background gone, captions must not follow it
        let after = cw.captionAlphasForTest
        check("live: at a fully transparent backdrop the window and the captions stay opaque",
              before.window == 1 && before.text == 1
              && after.window == 1 && after.text == 1 && after.backdrop == 0.0)
        // The alpha assertion above passed while the overlay rendered as an EMPTY see-through
        // window (a .behindWindow material ignores the view's alpha). Assert the fill exists.
        check("live: the overlay backdrop actually paints, sized to the content, beneath the captions",
              cw.backdropPaintsForTest)
        // caption-snapshot renders offscreen. That only tells the truth while nothing in the panel
        // is composited by the window server — so assert the render is not blank, and that the
        // blank-detector would have caught the old failure.
        cw.renderSampleCaptions()
        cw.setOpacityForTest(0.0)   // the transparent end, where the captions used to disappear
        let shot = cw.renderContentForTest()
        let emptyRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
        check("live: the overlay renders offscreen with visible captions, and a blank render is caught",
              shot != nil && !snapshotIsBlank(shot!)
              && snapshotIsBlank(emptyRep))   // the guard that stops a reassuring, empty PNG
        // …and nothing paints BEHIND it that the slider can't reach: `.hudWindow` slipped its own
        // full-window material into the theme frame, so the overlay never went fully transparent.
        check("live: no window-chrome material sits behind the backdrop (fully transparent is reachable)",
              cw.nothingPaintsBehindBackdropForTest)
        // With the background gone the panel loses every edge; the outline must not fade with it,
        // and must not steal the clicks that select text or drag the window.
        let e = cw.edgeSurvivesForTest
        check("live: the outline survives a fully transparent backdrop and never eats the mouse",
              e.visible && e.ignoresMouse)
        // …and it traces the window's rounded BOTTOM corners (radius 15), or a fully-transparent overlay
        // collapses to a bare rectangle. The top corners meet the square titlebar, so they stay sharp.
        let corner = cw.cornerRoundingForTest
        check("live: outline AND backdrop round the window's bottom corners (transparent overlay stays a window)",
              corner.edgeRadius == LiveCaptionWindow.windowCornerRadius && corner.edgeBottomOnly
              && corner.backdropRadius == LiveCaptionWindow.windowCornerRadius && corner.backdropBottomOnly)
        // The picker was built once at window creation: an engine switched off in Settings stayed
        // in the menu until the overlay was reopened. Assert it re-reads the ON list — never that
        // a particular engine is installed. `isReady` probes the filesystem and the Keychain, and
        // CI has neither whisper-cli nor its model, so pinning `[.whisper]` made this machine-dependent.
        // Assert it RE-READS the ON list. Which engines are *ready* depends on the machine —
        // `isReady` probes the filesystem, the Keychain and MR_*_KEY env vars — so the only thing
        // this can pin is that a saved change is picked up without reopening the overlay. What
        // gets picked from a given (ready, enabled) pair is `selectableLiveEngines`, tested purely.
        Pref.d.set([LiveEngine.apple.rawValue], forKey: Pref.liveEnginesOn)
        cw.reloadEngineChoices()
        let appleOnly = cw.engineChoicesForTest
        Pref.d.set(LiveEngine.allCases.map(\.rawValue), forKey: Pref.liveEnginesOn)
        cw.reloadEngineChoices()
        let allOn = cw.engineChoicesForTest
        Pref.d.removeObject(forKey: Pref.liveEnginesOn)
        check("live: reloadEngineChoices re-reads Settings instead of staying frozen at window creation",
              appleOnly == [.apple]                       // the ON list narrows the menu…
              && allOn.count >= appleOnly.count           // …and widening it re-reads, not caches
              && allOn.first == .apple                    // order follows allCases, apple first
              && !allOn.isEmpty)                          // never strands the user
    }
    // The harness drives the real UI, which persists as it goes: `caption-snapshot` left the user
    // in subtitle mode at zero opacity, and the next selftest read that back and failed. A test
    // subcommand must not be able to change the app's settings.
    // A pane taller than the window used to be cropped at the fold — the bottom of Summaries and
    // the whole Gladia section had never been rendered. The window grows to the document height,
    // floored at the runtime size and capped so a runaway pane can't produce an unopenable PNG.
    check("settings: a snapshot grows to the pane's full height, floored and capped",
          snapshotContentHeight(runtime: 600, document: 900) == 900       // taller pane → grow
          && snapshotContentHeight(runtime: 600, document: 400) == 600    // short pane → runtime floor
          && snapshotContentHeight(runtime: 600, document: 9999) == 4000) // runaway → capped
    check("prefs: the test harness writes to a throwaway suite, never the user's",
          Pref.suiteName == "com.ikhoon.macrec.prefs"     // the real one, still named here…
          && Pref.d.value(forKey: "__probe__") == nil)    // …but not the store the harness holds
    Pref.d.set("dirty", forKey: "__probe__")
    let realStore = UserDefaults(suiteName: Pref.suiteName)
    check("prefs: a write from the harness never reaches the user's suite",
          Pref.d.string(forKey: "__probe__") == "dirty"
          && realStore?.string(forKey: "__probe__") == nil)
    Pref.d.removeObject(forKey: "__probe__")

    // The harness must never read the user's real credentials, and every read is an authorization
    // check — an unsigned dev build turns each one into a password prompt.
    _ = Keychain.get("deepgram"); _ = Keychain.get("deepgram"); _ = Keychain.get("openai")
    check("keychain: the test harness never touches the real Keychain",
          Keychain.disabled && Keychain.readsForTest == 0 && Keychain.get("deepgram") == nil)
    // Asking whether an engine is READY must never ask for a SECRET — that is the authorization
    // prompt. Presence is answered by an attributes-only probe that hands nothing back.
    let secretsBefore = Keychain.secretRequestsForTest
    _ = LiveEngine.deepgram.isReady
    _ = LiveEngine.openai.isReady
    _ = selectableLiveEngines(LiveEngine.allCases, ready: { $0.isReady }, enabled: { $0.isEnabled })
    _ = sw.loadForTest()
    check("keychain: engine readiness and opening Settings request no secrets",
          Keychain.secretRequestsForTest == secretsBefore
          && sw.keyFieldsForTest.allSatisfy { $0.isEmpty || $0 == SettingsWindowController.keyMask })
    // MR_KEYCHAIN_ROUNDTRIP=1 drives the REAL Keychain against a throwaway account. It writes,
    // reads back, overwrites and deletes — proving `set` recreates the item (SecItemUpdate leaves
    // the creating process's ACL in place, which is how a credential ends up asking the wrong
    // binary for permission forever). Off by default: the harness must not touch credentials.
    if ProcessInfo.processInfo.environment["MR_KEYCHAIN_ROUNDTRIP"] == "1" {
        let acct = "selftest-roundtrip"
        Keychain.disabled = false
        Keychain.forgetCacheForTest()
        _ = Keychain.set(acct, "")                       // start clean
        let absent = !Keychain.exists(acct) && Keychain.get(acct) == nil
        let wrote = Keychain.set(acct, "first")
        Keychain.forgetCacheForTest()
        let readBack = Keychain.get(acct) == "first" && Keychain.exists(acct)
        let rewrote = Keychain.set(acct, "second")
        Keychain.forgetCacheForTest()
        let reread = Keychain.get(acct) == "second"
        _ = Keychain.set(acct, "")
        Keychain.forgetCacheForTest()
        let gone = !Keychain.exists(acct)
        Keychain.disabled = true
        check("keychain: real round-trip — write, read, recreate on overwrite, delete",
              absent && wrote && readBack && rewrote && reread && gone)
    }
    // A switch on + no key used to be silent: the engine simply never showed up in the picker.
    check("live: an engine switched on without its credential is reported, not silently dropped",
          enginesMissingCredentials(LiveEngine.allCases, enabled: { $0 == .deepgram || $0 == .apple },
                                    ready: { $0 == .apple }) == [.deepgram]
          && enginesMissingCredentials(LiveEngine.allCases, enabled: { _ in true }, ready: { _ in true }).isEmpty
          && enginesMissingCredentials(LiveEngine.allCases, enabled: { _ in false }, ready: { _ in false }).isEmpty)
    // The DeepL translation provider joins that same "you turned it on without a key" warning —
    // it used to save silently and just fall back to Apple. Engines + provider in one list.
    check("live: DeepL selected without a key is reported alongside missing-key engines",
          missingCredentialLabels(engines: [], engineEnabled: { _ in false }, engineReady: { _ in false },
                                  translationProvider: .deepl, deeplReady: false) == ["DeepL translation"]
          && missingCredentialLabels(engines: [], engineEnabled: { _ in false }, engineReady: { _ in false },
                                     translationProvider: .deepl, deeplReady: true).isEmpty     // key present → fine
          && missingCredentialLabels(engines: [], engineEnabled: { _ in false }, engineReady: { _ in false },
                                     translationProvider: .apple, deeplReady: false).isEmpty)   // Apple needs no key
    // Indexing allCases picked the wrong engine as soon as one was filtered out of the menu.
    check("live: a popup index maps into the FILTERED list, never into allCases",
          engineAtPopupIndex(1, choices: [.whisper, .deepgram, .openai, .gladia]) == .deepgram
          && engineAtPopupIndex(0, choices: [.deepgram]) == .deepgram
          && engineAtPopupIndex(99, choices: [.apple, .whisper]) == .whisper   // clamped, not a crash
          && engineAtPopupIndex(0, choices: []) == nil)
    // Turning cloud engines off by default must not silently downgrade someone already on one.
    check("live: an absent ON-list keeps on-device engines and grandfathers the engine already in use",
          liveEngineEnabled(.apple, storedOn: nil, selectedEngine: nil)
          && liveEngineEnabled(.whisper, storedOn: nil, selectedEngine: nil)
          && !liveEngineEnabled(.deepgram, storedOn: nil, selectedEngine: nil)
          && liveEngineEnabled(.deepgram, storedOn: nil, selectedEngine: "deepgram")   // the upgrade path
          && liveEngineEnabled(.deepgram, storedOn: ["deepgram"], selectedEngine: nil)
          && !liveEngineEnabled(.apple, storedOn: ["deepgram"], selectedEngine: "apple"))
    // ⌘V into a Settings field only works because the window is an EditableWindow — an LSUIElement
    // app has no Edit menu, so a plain NSWindow drops the key equivalent on the floor.
    check("settings: the window is an EditableWindow (⌘V/⌘C/⌘X/⌘A reach the field editor)",
          sw.window is EditableWindow)
    // Restarting the recorder discards the in-progress segment. Save must only do that when a
    // setting the recorder actually reads changed — Return in any text field fires Save now.
    let fpA = engineFingerprint(["voiceMin": "5", "exclude": "com.spotify.client"])
    check("settings: the engine fingerprint changes iff an engine-affecting pref changed",
          fpA == engineFingerprint(["exclude": "com.spotify.client", "voiceMin": "5"])   // order-independent
          && fpA != engineFingerprint(["voiceMin": "3", "exclude": "com.spotify.client"])
          && !SettingsWindowController.engineKeysForTest.contains(Pref.liveEnginesOn)
          && !SettingsWindowController.engineKeysForTest.contains(Pref.dailyDigestName))
    // Every pref that must make Save restart the recorder. Omitting one means the setting saves
    // and nothing happens — turning the schedule OFF left the engine parked off-hours, because
    // only restartEngine() clears `schedulePaused` and re-baselines the schedule.
    let mustRestart = [Pref.schedEnabled, Pref.schedDays, Pref.schedHours, Pref.calGated, Pref.calGatePad,
                       Pref.segment, Pref.model, Pref.customModel, Pref.lang, Pref.exclude, Pref.txtDir,
                       Pref.audioDir, Pref.systemAudio, Pref.echoReduce, Pref.vad, Pref.keepAudio,
                       Pref.voiceMin, Pref.cal, Pref.calendars, Pref.hintsTerms, Pref.hintsFile, Pref.hintsCalendar]
    check("settings: every recorder-affecting pref (schedule included) forces an engine restart on Save",
          mustRestart.allSatisfy { SettingsWindowController.engineKeysForTest.contains($0) })
    check("settings: a count field is valid iff empty or a non-negative integer (else red-on-invalid)",
          numericFieldValid("") && numericFieldValid("  ") && numericFieldValid("5") && numericFieldValid("0")
          && !numericFieldValid("-1") && !numericFieldValid("abc") && !numericFieldValid("5.5") && !numericFieldValid("1 2"))
    check("settings: controlTextDidChange actually tints the field (red on invalid, label on valid/empty)",
          sw.numericTintForTest("-1") == .systemRed && sw.numericTintForTest("abc") == .systemRed
          && sw.numericTintForTest("5") == .labelColor && sw.numericTintForTest("") == .labelColor)
    // The echo canceller must be fed the FULL speaker mix, not the transcript's filtered one — an
    // excluded app (Spotify) still plays out loud and bleeds into the mic, so a reference missing
    // it can never cancel that bleed. The dedicated full-mix reference tap is stood up only when
    // echo reduction is on AND something is excluded (with nothing excluded the filtered tap already
    // IS the full mix). This is the exact guard CaptureSession.startReferenceTap uses.
    check("aec: stand up the full-mix reference tap only when echo reduction is on AND apps are excluded",
          shouldStartReferenceTap(echoReduceEnabled: true,  hasExcludedApps: true)   // the one case that needs it
          && !shouldStartReferenceTap(echoReduceEnabled: true,  hasExcludedApps: false) // nothing excluded → filtered IS full
          && !shouldStartReferenceTap(echoReduceEnabled: false, hasExcludedApps: true)  // AEC off → moot
          && !shouldStartReferenceTap(echoReduceEnabled: false, hasExcludedApps: false))
    // System-audio exclusion: match on Core Audio's own process list, so a helper process that
    // plays under its own bundle id is at least VISIBLE (AppKit's app lookup never saw it), and
    // notice when a relaunch (new object id) has made the live tap's frozen exclusion set stale.
    let procs = [AudioProcessInfo(objectID: 501, bundleID: "com.spotify.client"),
                 AudioProcessInfo(objectID: 502, bundleID: "com.spotify.client.helper"),
                 AudioProcessInfo(objectID: 503, bundleID: nil)]
    check("audio: exclusion matches Core Audio's bundle ids; unattributed processes are never excluded",
          matchExcludedProcesses(procs, excludeBundleIds: ["com.spotify.client"]) == [501]
          && matchExcludedProcesses(procs, excludeBundleIds: ["com.spotify.client", "com.spotify.client.helper"]) == [501, 502]
          && matchExcludedProcesses(procs, excludeBundleIds: []).isEmpty)
    check("audio: a relaunched excluded app (new object id) makes the live tap's exclusion stale",
          tapExclusionIsStale(current: [222], live: [111])          // relaunch — the reported bug
          && tapExclusionIsStale(current: [111], live: [])          // launched after the tap was built
          && !tapExclusionIsStale(current: [111, 222], live: [222, 111]))   // same set, any order
    // The tap's aggregate is pinned to the default output at creation; a mid-meeting output switch used to
    // be missed entirely (the guard only checked exclusions), so audio silently stopped — the SoundSource /
    // BlackHole / headphones case. Now a changed output UID makes the tap stale and triggers a rebuild.
    check("audio: a default-output change makes the live tap stale (mid-meeting output switch was silent)",
          tapOutputIsStale(current: "BlackHole2ch", live: "BuiltInSpeakerDevice")
          && tapOutputIsStale(current: nil, live: "BuiltInSpeakerDevice")
          && !tapOutputIsStale(current: "Same", live: "Same"))
    check("audio: shouldRebuildTap fires on EITHER an exclusion OR an output drift (not just exclusions)",
          shouldRebuildTap(currentExclusions: [111], liveExclusions: [111],
                           currentOutputUID: "BlackHole2ch", liveOutputUID: "BuiltInSpeaker")   // output only
          && shouldRebuildTap(currentExclusions: [222], liveExclusions: [111],
                              currentOutputUID: "Same", liveOutputUID: "Same")                   // exclusion only
          && !shouldRebuildTap(currentExclusions: [111], liveExclusions: [111],
                               currentOutputUID: "Same", liveOutputUID: "Same"))                 // neither → no churn
    // Credentials are a 0600 file now, not the login keychain (which re-prompted "allow access" on every
    // rebuild — the modern SecItemAdd ignores a custom ACL). Exercise the real read/write path against a
    // throwaway file: set → get round-trips, exists reflects it, empty removes, and the file is 0600.
    do {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mr-cred-\(UUID().uuidString).json")
        let wasDisabled = Keychain.disabled
        Keychain.disabled = false; Keychain.fileOverrideForTest = tmp; Keychain.forgetCacheForTest()
        _ = Keychain.set("openai", "sk-test-123")
        let got = Keychain.get("openai"), has = Keychain.exists("openai"), missing = Keychain.exists("deepl")
        _ = Keychain.set("openai", "")   // empty removes the key
        let cleared = Keychain.get("openai")
        let perms = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.posixPermissions] as? NSNumber)??.intValue
        try? FileManager.default.removeItem(at: tmp)
        Keychain.fileOverrideForTest = nil; Keychain.disabled = wasDisabled; Keychain.forgetCacheForTest()
        check("cred: 0600 file store round-trips (set/get/exists/remove), never touches the keychain",
              got == "sk-test-123" && has && !missing && cleared == nil && perms == 0o600)
    }
    // Sidebar selection is app state, not focus state: the accent pill must survive AppKit
    // clearing isEmphasized when focus moves to a text field (it looked like a random blue blink).
    let sidebarRow = SidebarRowView()
    sidebarRow.isEmphasized = false
    check("settings: sidebar selection stays accent-filled when the table loses focus",
          sidebarRow.isEmphasized)
    // Click/label/enablement all route through togglePauseShouldResume — test the REAL decision
    // the bug lived in (togglePause resumed only `if paused`, ignoring schedule-pause).
    check("tray: schedule-paused resumes on click (the bug), manual-pause resumes, idle does not",
          togglePauseShouldResume(paused: false, schedulePaused: true)      // off-hours → Resume (the fix)
          && togglePauseShouldResume(paused: true, schedulePaused: false)   // manual pause → Resume
          && !togglePauseShouldResume(paused: false, schedulePaused: false))// recording/idle → Pause
    // Grant item hides only once BOTH capture grants are in (calendar excluded on purpose).
    check("tray: Grant permissions hidden only when audio AND mic granted",
          captureGrantsSatisfied(audioGranted: true, micGranted: true)
          && !captureGrantsSatisfied(audioGranted: false, micGranted: true)
          && !captureGrantsSatisfied(audioGranted: true, micGranted: false))
    // Choose… presents as a SHEET on a visible window (bare runModal opens behind on an
    // .accessory app — the "Choose did nothing" bug); no visible window → activate + runModal.
    check("settings: dir picker uses a sheet iff there is a visible window",
          dirPickerPresentation(hasVisibleWindow: true) == .sheet
          && dirPickerPresentation(hasVisibleWindow: false) == .activateAndRunModal)
    // Update-alert Open URL: none for brew; https release URL otherwise; a non-https scheme or a
    // blank/missing API url falls back to the https releases page — never opens an unsafe scheme.
    check("update alert: brew→no button; https htmlURL→that exact link; http/non-https/blank→https releases fallback; unsafe releases→nil",
          updateAlertOpenURL(installedViaBrew: true, htmlURL: "https://x/y", releasesURL: UpdateChecker.releasesURL) == nil
          && updateAlertOpenURL(installedViaBrew: false, htmlURL: "https://github.com/ikhoon/macrec/releases/tag/v9", releasesURL: UpdateChecker.releasesURL)?.absoluteString == "https://github.com/ikhoon/macrec/releases/tag/v9"
          && updateAlertOpenURL(installedViaBrew: false, htmlURL: "http://x/y", releasesURL: UpdateChecker.releasesURL)?.absoluteString == UpdateChecker.releasesURL
          && updateAlertOpenURL(installedViaBrew: false, htmlURL: "javascript:alert(1)", releasesURL: UpdateChecker.releasesURL)?.absoluteString == UpdateChecker.releasesURL
          && updateAlertOpenURL(installedViaBrew: false, htmlURL: "", releasesURL: UpdateChecker.releasesURL)?.absoluteString == UpdateChecker.releasesURL
          && updateAlertOpenURL(installedViaBrew: false, htmlURL: nil, releasesURL: "file:///etc/passwd") == nil)
    // The menu-bar brand mark actually draws in every state (not an all-transparent image — the
    // "structurally valid but visually destroyed" class of bug). LOOK via `macrec icon-snapshot`.
    check("tray icon: brand mark renders content (recording, recording+voice, paused)",
          brandMarkHasContent(recording: true, voice: true)
          && brandMarkHasContent(recording: true, voice: false)
          && brandMarkHasContent(recording: false, voice: false))
    // Short-blip filter: no overlapping meeting + under 3 min of speech → no file (user rule).
    check("keep transcript: meeting always kept; no meeting needs ≥3 min speech",
          shouldKeepTranscript(hasMeeting: true, speechSeconds: 5)
          && shouldKeepTranscript(hasMeeting: false, speechSeconds: 180)
          && shouldKeepTranscript(hasMeeting: false, speechSeconds: 240)
          && !shouldKeepTranscript(hasMeeting: false, speechSeconds: 179)
          && !shouldKeepTranscript(hasMeeting: false, speechSeconds: 0))
    // Summaries Mode is a real TAB — it SHOWS only the selected mode's sections (not readonly
    // greying). Switch each mode and confirm only that group is visible.
    sw.setPPModeForTest("summary")
    check("summaries tab: Automatic summary shown, Custom command + off hidden",
          sw.ppGroupVisibleForTest("pp.summary")
          && !sw.ppGroupVisibleForTest("pp.shell") && !sw.ppGroupVisibleForTest("pp.off"))
    sw.setPPModeForTest("shell")
    check("summaries tab: Custom command shown, Automatic summary hidden",
          sw.ppGroupVisibleForTest("pp.shell") && !sw.ppGroupVisibleForTest("pp.summary"))
    sw.setPPModeForTest("off")
    check("summaries tab: off note shown, both mode sections hidden",
          sw.ppGroupVisibleForTest("pp.off")
          && !sw.ppGroupVisibleForTest("pp.summary") && !sw.ppGroupVisibleForTest("pp.shell"))
}
