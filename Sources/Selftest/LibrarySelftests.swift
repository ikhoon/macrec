import AppKit
import AVFoundation
import Foundation

/// Fixture days for the layout/snapshot harness — invented names only (public-repo rule: never a
/// real meeting title, host, or org identifier in a fixture).
func libraryFixtureDays() -> [LibraryDay] {
    let u = URL(fileURLWithPath: "/tmp/library-fixture.md")
    let a = URL(fileURLWithPath: "/tmp/library-fixture.wav")
    return [
        // Hand-built test data (index-addressed by many tests below) — NOT a claim about scan order;
        // the real digest-first, earliest→latest ordering is covered by the librarySortedEntries test.
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
    // #34: the tray "summary:" row opens IN-APP — libraryEntryToSelect finds the row for a given file.
    // A transcript matches by its SUMMARY (so the Summary view opens on it); a digest by its own file;
    // a redundant path component (./ or ../) still matches (standardized); an unknown file → nil.
    let tx = URL(fileURLWithPath: "/tmp/s1.md"), sum = URL(fileURLWithPath: "/tmp/s1-sum.md")
    let dig = URL(fileURLWithPath: "/tmp/2026-03-02.md")
    let selDays = [LibraryDay(day: "2026-03-02", entries: [
        LibraryEntry(day: "2026-03-02", time: nil, title: nil, kind: .digest, url: dig, summaryURL: nil, audioURL: nil),
        LibraryEntry(day: "2026-03-02", time: "14:00", title: "a", kind: .transcript, url: tx, summaryURL: sum, audioURL: nil),
    ])]
    let selBySummary = libraryEntryToSelect(days: selDays, target: sum)
    check("library: entry-to-select finds the row by summary or own file, standardizes, else nil",
          selBySummary?.url == tx && selBySummary?.kind == .transcript                                       // via summaryURL
              && libraryEntryToSelect(days: selDays, target: dig)?.kind == .digest                           // via own file
              && libraryEntryToSelect(days: selDays, target: URL(fileURLWithPath: "/tmp/x/../s1-sum.md"))?.url == tx  // standardized
              && libraryEntryToSelect(days: selDays, target: URL(fileURLWithPath: "/tmp/nope.md")) == nil)
    // Review: roots expand "~" symmetrically with the WRITE side — a typed "~/dir" summary root must
    // not be scanned literally (else the tray click dead-ends on a file written to the real path).
    check("library: roots expand ~ symmetrically (typed ~/dir isn't scanned literally)",
          !libraryRoots(transcripts: "~/t", summaryOut: "~/s", dailyOut: "", audioDir: "").summaries.hasPrefix("~")
              && libraryRoots(transcripts: "/abs", summaryOut: "", dailyOut: "", audioDir: "").summaries == "/abs")
    // WIRING (dead-affordance lesson): the tray summary row drives the REAL show(selecting:) logic to
    // land its right pane ON the summary AND on the digest (a distinct picker-hidden branch) — not just
    // the pure matcher. Both fixture rows have no file on disk, so they must resolve via the index.
    let wTx = URL(fileURLWithPath: "/tmp/wire-tx.md"), wSum = URL(fileURLWithPath: "/tmp/wire-sum.md")
    let wDig = URL(fileURLWithPath: "/tmp/wire-2026-03-02.md")
    LibraryWindow.shared.loadFixtureForTest([LibraryDay(day: "2026-03-02", entries: [
        LibraryEntry(day: "2026-03-02", time: nil, title: nil, kind: .digest, url: wDig, summaryURL: nil, audioURL: nil),
        LibraryEntry(day: "2026-03-02", time: "14:00", title: "x", kind: .transcript, url: wTx, summaryURL: wSum, audioURL: nil),
    ])])
    check("library: tray row opens the Library ON the summary AND the digest (in-app, not Finder)",
          LibraryWindow.shared.showSelectingForTest(wSum) == wSum      // transcript → its Summary
              && LibraryWindow.shared.showSelectingForTest(wDig) == wDig)   // digest → its own file (picker hidden)
    // A target on disk but NOT indexed (orphaned summary / custom-named digest) renders IN-APP directly
    // — never a dead click, never Finder (review P1). An absent file → nil.
    let orphan = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macrec-orphan-\(UUID().uuidString).md")
    try? "# orphan\n\nbody".write(to: orphan, atomically: true, encoding: .utf8)
    check("library: an on-disk-but-unindexed summary renders in-app, not a dead click; absent → nil",
          LibraryWindow.shared.showSelectingForTest(orphan) == orphan
              && LibraryWindow.shared.showSelectingForTest(URL(fileURLWithPath: "/tmp/absent-\(UUID().uuidString).md")) == nil)
    try? FileManager.default.removeItem(at: orphan)
    LibraryWindow.shared.loadFixtureForTest(libraryFixtureDays())   // restore the rich default

    // #37: deleting a recording removes the transcript + its summary + audio (BOTH the raw .wav and the
    // archived .m4a); a digest deletes only itself. Pure decision, then the real performDelete loop.
    let dTx = URL(fileURLWithPath: "/tmp/2026-03-02-1400-x.md")
    let dSum = URL(fileURLWithPath: "/tmp/2026-03-02-1400-x-sum.md")
    let dWav = URL(fileURLWithPath: "/tmp/2026-03-02-1400-x.wav")
    let dM4a = URL(fileURLWithPath: "/tmp/2026-03-02-1400-x.m4a")
    let delEntry = LibraryEntry(day: "2026-03-02", time: "14:00", title: "x", kind: .transcript,
                                url: dTx, summaryURL: dSum, audioURL: dWav)
    let dset = libraryDeletionSet(delEntry)
    // digest deletes its .md AND the #146 structured .json sidecar next to it; an audio-only row where
    // url == audioURL exercises the dedup (the .wav appears once, plus the .m4a sibling) → count 2.
    let digMd = URL(fileURLWithPath: "/tmp/2026-03-02.md")
    let digestEntry = LibraryEntry(day: "2026-03-02", time: nil, title: nil, kind: .digest, url: digMd, summaryURL: nil, audioURL: nil)
    let audioOnly = LibraryEntry(day: "d", time: "17:00", title: nil, kind: .audio,
                                 url: dM4a, summaryURL: nil, audioURL: dM4a)
    check("library: deletion set covers transcript+summary+audio(both), digest+.json, and dedups audio-only",
          dset.count == 4 && dset.contains(dTx) && dset.contains(dSum) && dset.contains(dWav) && dset.contains(dM4a)
              && libraryDeletionSet(digestEntry) == [digMd, URL(fileURLWithPath: "/tmp/2026-03-02.json")]
              && libraryDeletionSet(audioOnly) == [dM4a, URL(fileURLWithPath: "/tmp/2026-03-02-1400-x.wav")])   // dedup: .m4a once + .wav
    // WIRING (dead-affordance + destructive-op discipline): performDelete removes the real files on disk
    // (remove injected = removeItem, no Trash litter), reports failures (empty here), and clears the pane.
    let ddir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macrec-del-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: ddir, withIntermediateDirectories: true)
    let fTx = ddir.appendingPathComponent("m.md"), fSum = ddir.appendingPathComponent("m-sum.md")
    let fWav = ddir.appendingPathComponent("m.wav")
    for u in [fTx, fSum, fWav] { try? "x".write(to: u, atomically: true, encoding: .utf8) }
    let fEntry = LibraryEntry(day: "2026-03-02", time: "14:00", title: "m", kind: .transcript,
                              url: fTx, summaryURL: fSum, audioURL: fWav)
    LibraryWindow.shared.loadFixtureForTest([LibraryDay(day: "2026-03-02", entries: [fEntry])])
    LibraryWindow.shared.selectForTest(fEntry)   // so the delete clears the pane (selected == e)
    let failed = LibraryWindow.shared.performDelete(fEntry, remove: { try FileManager.default.removeItem(at: $0) })
    let dfm = FileManager.default
    check("library: delete removes the 3 files, reports no failure, and clears the pane",
          failed.isEmpty && !dfm.fileExists(atPath: fTx.path) && !dfm.fileExists(atPath: fSum.path)
              && !dfm.fileExists(atPath: fWav.path) && !LibraryWindow.shared.openEnabledForTest)   // pane cleared → Open off
    try? dfm.removeItem(at: ddir)
    // Delete's enablement diverges from Open/Reveal: ON for a real entry, OFF for the empty pane AND
    // the #34 standalone render (no indexed entry / related files). Pinned so a refactor can't re-enable it.
    LibraryWindow.shared.loadFixtureForTest(libraryFixtureDays())
    LibraryWindow.shared.selectForTest(libraryFixtureDays()[0].entries[1])   // a real transcript row
    let onReal = LibraryWindow.shared.deleteEnabledForTest
    LibraryWindow.shared.selectForTest(nil)
    let onEmpty = LibraryWindow.shared.deleteEnabledForTest
    let orphanFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macrec-del-orphan-\(UUID().uuidString).md")
    try? "# x".write(to: orphanFile, atomically: true, encoding: .utf8)
    _ = LibraryWindow.shared.showSelectingForTest(orphanFile)   // standalone render (not indexed)
    let onStandalone = LibraryWindow.shared.deleteEnabledForTest
    try? dfm.removeItem(at: orphanFile)
    check("library: Delete is enabled for a real entry, disabled for the empty pane and standalone render",
          onReal && !onEmpty && !onStandalone)
    // Empty selection hides the WHOLE action strip (user report: an empty day pick left orphaned
    // Open/Reveal buttons over a void); a selection or a standalone render brings it back.
    LibraryWindow.shared.selectForTest(nil)
    let stripHiddenEmpty = LibraryWindow.shared.headBarHiddenForTest
    LibraryWindow.shared.selectForTest(libraryFixtureDays()[0].entries[1])
    let stripShownSelected = !LibraryWindow.shared.headBarHiddenForTest
    let orphan2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macrec-strip-\(UUID().uuidString).md")
    try? "# t".write(to: orphan2, atomically: true, encoding: .utf8)
    _ = LibraryWindow.shared.showSelectingForTest(orphan2)
    let stripShownStandalone = !LibraryWindow.shared.headBarHiddenForTest
    try? FileManager.default.removeItem(at: orphan2)
    check("library: the action strip hides on empty selection, returns on select and standalone",
          stripHiddenEmpty && stripShownSelected && stripShownStandalone)
    LibraryWindow.shared.loadFixtureForTest(libraryFixtureDays())   // restore
    // The LIST-side delete (user ask): every entry row renders a wired trash button bound to its OWN
    // entry — a recycled cell bound to a stale entry would trash the wrong recording on scroll.
    let rowDel = LibraryWindow.shared.rowDeleteBindingsForTest()
    check("library: every list row carries a wired trash button bound to its own entry",
          rowDel.rows > 0 && rowDel.bound == rowDel.rows)
    // CLICK-THROUGH: wiring metadata alone can't prove a tap ARRIVES — fire a
    // real performClick on a row's trash and assert the target/action chain resolved confirmDelete
    // with that row's OWN entry (the hook stands in for the modal sheet, headless).
    var clickedEntry: LibraryEntry?
    LibraryWindow.shared.confirmDeleteHookForTest = { clickedEntry = $0 }
    let kickoffRow = (0 ..< 20).first {
        (LibraryWindow.shared.outlineItemForTest(row: $0) as? LibraryEntry)?.title == "project kickoff"
    }
    let clicked = kickoffRow.map { LibraryWindow.shared.clickRowDeleteForTest(row: $0) } ?? false
    LibraryWindow.shared.confirmDeleteHookForTest = nil
    check("library: a real click on a row's trash resolves confirmDelete with that row's entry",
          clicked && clickedEntry?.title == "project kickoff" && clickedEntry?.kind == .transcript)

    // The calendar sidebar (user ask): the pure month grid — cells land on the right weekdays, the
    // month pads to whole weeks, leap February exists, and ‹ › arithmetic crosses year boundaries.
    // A FIXED calendar (gregorian, Sunday-first, Seoul) — a test reading the machine's calendar
    // passes here and fails on a Monday-first laptop (the environment decides the answer).
    var cal = Calendar(identifier: .gregorian)
    cal.firstWeekday = 1
    cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
    cal.locale = Locale(identifier: "en_US_POSIX")
    let july = monthGrid("2026-07", calendar: cal)   // 2026-07-01 is a Wednesday
    let feb = monthGrid("2024-02", calendar: cal)    // leap month, 29 days
    check("library calendar: grid weekday placement, whole-week padding, leap month, ‹ › across years",
          july.count == 5 && july[0][3] == "2026-07-01" && july[0][2] == nil
              && july[4][5] == "2026-07-31" && july[4][6] == nil
              && feb.joined().compactMap { $0 }.count == 29 && feb[0][4] == "2024-02-01"
              && monthShift("2026-01", by: -1, calendar: cal) == "2025-12"
              && monthShift("2026-12", by: 1, calendar: cal) == "2027-01"
              // CONTENT, not count (count==7 is true by construction — a vacuous pin): Sunday-first
              // English letters, exactly. The view builds its own gregorian/POSIX calendar the same way.
              && weekdayHeaders(calendar: cal) == ["S", "M", "T", "W", "T", "F", "S"]
              && libraryGridCalendar(from: cal).identifier == .gregorian)
    // Month VIEW: a day cell shows the first N entries as chips, the rest fold into a "+N" overflow, and
    // each chip's label reads by kind (digest / audio / a titled transcript). entriesByDayMap keys lookups.
    let mvU = URL(fileURLWithPath: "/tmp/mv.md"), mvA = URL(fileURLWithPath: "/tmp/mv.wav")
    let mvDigest = LibraryEntry(day: "2026-03-02", time: nil, title: nil, kind: .digest, url: mvU, summaryURL: nil, audioURL: nil)
    let mvT1 = LibraryEntry(day: "2026-03-02", time: "10:30", title: "standup", kind: .transcript, url: mvU, summaryURL: nil, audioURL: nil)
    let mvAudio = LibraryEntry(day: "2026-03-02", time: "17:52", title: nil, kind: .audio, url: mvA, summaryURL: nil, audioURL: mvA)
    let mvUntitled = LibraryEntry(day: "d", time: "09:00", title: nil, kind: .transcript, url: mvU, summaryURL: nil, audioURL: nil)
    let mvDays = [LibraryDay(day: "2026-03-02", entries: [mvDigest, mvT1, mvAudio])]
    let mvCell = monthCellChips([mvDigest, mvT1, mvAudio, mvT1, mvT1], max: 3)
    check("library month-view: cell shows N chips + overflow, and chip labels read by kind",
          mvCell.chips.count == 3 && mvCell.overflow == 2
              && monthChipLabel(mvDigest) == "Daily digest"
              && monthChipLabel(mvT1) == "10:30  standup"
              && monthChipLabel(mvAudio) == "17:52  audio"
              && monthChipLabel(mvUntitled) == "09:00  (untitled)"
              && monthCellChips([mvDigest], max: 3).overflow == 0
              && entriesByDayMap(mvDays)["2026-03-02"]?.count == 3)
    // The day filter is one more pure input: only that day's group survives, it composes with the
    // kind scope, and nil means every day (the existing behavior, unchanged).
    let fixDays = libraryFixtureDays()
    check("library calendar: the day filter keeps one day, composes with kind, nil keeps all",
          libraryFiltered(fixDays, filter: "", day: "2026-03-01").map(\.day) == ["2026-03-01"]
              && libraryFiltered(fixDays, filter: "", onlyKind: .digest, day: "2026-03-01").isEmpty
              && libraryFiltered(fixDays, filter: "", day: nil).count == fixDays.count
              && libraryFiltered(fixDays, filter: "", day: "2020-01-01").isEmpty)
    // WIRING: a pick through the REAL calendar view filters the outline to that day; picking the
    // same day again clears it (toggle). The month opens where the data is: a TWO-month fixture —
    // with every fixture day in one month, "follows the newest" and "any month with data" would be
    // indistinguishable and the assertion vacuous (review finding).
    var twoMonths = libraryFixtureDays()
    twoMonths.append(LibraryDay(day: "2026-02-27", entries: [
        LibraryEntry(day: "2026-02-27", time: "11:00", title: "sprint review", kind: .transcript,
                     url: URL(fileURLWithPath: "/tmp/library-fixture.md"), summaryURL: nil, audioURL: nil),
    ]))
    LibraryWindow.shared.loadFixtureForTest(twoMonths)
    LibraryWindow.shared.calendarPickForTest("2026-03-01")
    let picked = (LibraryWindow.shared.selectedDayForTest, LibraryWindow.shared.shownDayCountForTest)
    LibraryWindow.shared.calendarPickForTest("2026-03-01")
    let cleared = (LibraryWindow.shared.selectedDayForTest, LibraryWindow.shared.shownDayCountForTest)
    check("library calendar: a pick filters the list to that day, a re-pick clears, month follows data",
          picked == ("2026-03-01", 1) && cleared.0 == nil && cleared.1 == 3
              && LibraryWindow.shared.calendarMonthForTest == "2026-03"   // newest month, not February
              && LibraryWindow.shared.calendarDayButtonCountForTest() == 31)   // March renders 31 day buttons
    // The grid height is CONSTANT (always 6 week rows): a 5-week month would bounce the list ~23px
    // on every ‹ › page. And the auto-follow contract: the month tracks the newest data only until
    // the user pages — then their browsing owns it and a rescan must not snap it back.
    let sixRows = LibraryWindow.shared.calendarWeekRowCountForTest()
    LibraryWindow.shared.calendarFlipForTest(by: -1)   // → 2026-02, user-navigated
    LibraryWindow.shared.loadFixtureForTest(twoMonths) // rescan while browsed away
    check("library calendar: constant 6-week height; a browsed month survives a rescan",
          sixRows == 6 && LibraryWindow.shared.calendarMonthForTest == "2026-02"
              && LibraryWindow.shared.calendarWeekRowCountForTest() == 6)
    // The ✕ chip is the only always-reachable clear once the user pages AWAY from the picked day's
    // month — the picked cell (the toggle) is then off-screen. Real controls:
    // the pick lands on a RENDERED button (the honest seam refuses an off-grid date), the flip goes
    // through ‹, and the chip's performClick restores every day.
    LibraryWindow.shared.calendarFlipForTest(by: 1)   // back to 2026-03 (the 6-week check left Feb shown)
    let pickLanded = LibraryWindow.shared.calendarPickForTest("2026-03-01")
    LibraryWindow.shared.calendarFlipForTest(by: -1)  // browse to February — the picked cell is gone
    let offGridPick = LibraryWindow.shared.calendarPickForTest("2026-03-01")   // not rendered → false
    let chipCleared = LibraryWindow.shared.calendarClickClearForTest()
    check("library calendar: the ✕ chip clears a filter whose day is off the browsed month's grid",
          pickLanded && !offGridPick && chipCleared
              && LibraryWindow.shared.selectedDayForTest == nil
              && LibraryWindow.shared.shownDayCountForTest == 3
              && !LibraryWindow.shared.calendarClickClearForTest())   // chip hides once cleared
    // The tray deep-link clears an active day filter AND the calendar highlight must follow — a
    // stale view copy makes the next click on that day a dead toggle (review P1).
    LibraryWindow.shared.loadFixtureForTest(twoMonths)
    LibraryWindow.shared.calendarFlipForTest(by: 1)   // back to 2026-03 where the pick target renders
    LibraryWindow.shared.calendarPickForTest("2026-03-01")
    _ = LibraryWindow.shared.showSelectingForTest(URL(fileURLWithPath: "/tmp/library-fixture.md"))
    let syncedOff = LibraryWindow.shared.calendarSelectedDayForTest == nil
        && LibraryWindow.shared.selectedDayForTest == nil
    let repick = LibraryWindow.shared.calendarPickForTest("2026-03-01")   // first click must FILTER, not dead-toggle
    check("library calendar: a deep-link clears the highlight too — the next pick filters first-click",
          syncedOff && repick && LibraryWindow.shared.selectedDayForTest == "2026-03-01"
              && LibraryWindow.shared.shownDayCountForTest == 1)
    // The window is a SINGLETON — clear the pick and restore the default fixture, or the leftover
    // day filter leaks into every later check (it silently emptied the scope/re-run suites once).
    LibraryWindow.shared.calendarPickForTest("2026-03-01")   // toggle the pick back off
    LibraryWindow.shared.loadFixtureForTest(libraryFixtureDays())

    // Windowed-app lifecycle: a Dock identity only while the Library is up, and ⌘Q downgrades to a
    // window close UNLESS the quit is deliberate (tray Quit) or system-initiated (SIGTERM/logout —
    // cancelling those would block shutdown and starve the watchdog's clean-exit path).
    check("appearance: mode maps to aqua/darkAqua and system means no override",
          appearanceName(for: "light") == .aqua && appearanceName(for: "dark") == .darkAqua
              && appearanceName(for: "system") == nil && appearanceName(for: "garbage") == nil)
    // The OBSERVABLE effect, not just the mapper: the saved pref drives NSApp.appearance (ephemeral
    // suite; the prior appearance is restored so the selftest leaves the process as it found it).
    let priorAppearance = NSApp.appearance
    Pref.d.set("dark", forKey: Pref.appearanceMode); applySavedAppearance()
    let appliedDark = NSApp.appearance?.name == .darkAqua
    Pref.d.set("system", forKey: Pref.appearanceMode); applySavedAppearance()
    let appliedSystem = NSApp.appearance == nil
    NSApp.appearance = priorAppearance
    Pref.d.removeObject(forKey: Pref.appearanceMode)
    check("appearance: the saved mode is APPLIED to NSApp and system clears the override",
          appliedDark && appliedSystem)
    // Main-window sections: the nav swap is REAL (panes show/hide, status rows materialize from the
    // injected sample, the live mirror lands in the pane) — not just a stored enum.
    var healthFix = HealthInputs()
    healthFix.audioGranted = true; healthFix.micGranted = true; healthFix.calendarGranted = true
    healthFix.recording = true; healthFix.modelReady = true; healthFix.modelName = "large-v3"
    healthFix.whisperResolved = true; healthFix.runnerResolved = true; healthFix.runnerName = "claude"
    LibraryWindow.shared.healthSample = { healthFix }
    LibraryWindow.shared.switchSectionForTest(.status)
    let statusRows = LibraryWindow.shared.statusRowCountForTest
    let statusShown = !LibraryWindow.shared.statusPaneHiddenForTest && LibraryWindow.shared.headBarHiddenForTest
    LibraryWindow.shared.switchSectionForTest(.live)
    LibraryWindow.shared.liveMirror(NSAttributedString(string: "mirror check line"))
    let liveShown = !LibraryWindow.shared.livePaneHiddenForTest
        && LibraryWindow.shared.liveMirrorTextForTest.contains("mirror check line")
    LibraryWindow.shared.switchSectionForTest(.library)
    let backToLib = LibraryWindow.shared.livePaneHiddenForTest
    LibraryWindow.shared.liveMirror(NSAttributedString(string: "captured before open"))   // arrives off-screen
    LibraryWindow.shared.switchSectionForTest(.live)
    let replayed = LibraryWindow.shared.liveMirrorTextForTest.contains("captured before open")
    LibraryWindow.shared.switchSectionForTest(.library)
    LibraryWindow.shared.healthSample = nil
    check("main window: nav swaps Live/Library/Status panes with real content",
          statusRows > todayHealth(healthFix).count / 2 && statusShown && liveShown && backToLib && replayed)
    // The nav round-trip regression: with an audio row selected, leave Library and come back — the
    // player bar must re-derive from the selection, not latch the force-hidden state forever.
    LibraryWindow.shared.selectForTest(libraryFixtureDays()[0].entries[1])   // has audioURL
    LibraryWindow.shared.switchSectionForTest(.status)
    LibraryWindow.shared.switchSectionForTest(.library)
    check("main window: the player bar survives a section round-trip for an audio row",
          !LibraryWindow.shared.playerBarHiddenForTest)
    // The other three sprint fixes, asserted through real wiring:
    // (a) the summary bar never bleeds over Status/Live and returns with Library;
    LibraryWindow.shared.switchSectionForTest(.status)
    let barGated = LibraryWindow.shared.summaryBarHiddenForTest
    LibraryWindow.shared.switchSectionForTest(.library)
    let barBack = !LibraryWindow.shared.summaryBarHiddenForTest   // transcript row selected → export eligible
    // (b) the 1 Hz Status tick repaints a CHANGED sample (run the loop past one tick);
    var tickFix = healthFix
    LibraryWindow.shared.healthSample = { tickFix }
    LibraryWindow.shared.switchSectionForTest(.status)
    let rowsBefore = LibraryWindow.shared.statusRowCountForTest
    tickFix.notificationsDenied = true
    RunLoop.main.run(until: Date().addingTimeInterval(1.3))
    let rowsAfter = LibraryWindow.shared.statusRowCountForTest
    LibraryWindow.shared.switchSectionForTest(.library)
    let timerGone = !LibraryWindow.shared.statusTimerLiveForTest
    LibraryWindow.shared.healthSample = nil
    // (c) a stop clears the pending mirror — a dead session must not replay.
    LibraryWindow.shared.liveMirror(NSAttributedString(string: "captured before stop"))
    LibraryWindow.shared.liveMirrorClear()
    LibraryWindow.shared.switchSectionForTest(.live)
    let notReplayed = !LibraryWindow.shared.liveMirrorTextForTest.contains("captured before stop")
    LibraryWindow.shared.switchSectionForTest(.library)
    check("main window: bar gating, live status tick, and stop-clear all hold",
          barGated && barBack && rowsAfter == rowsBefore + 1 && timerGone && notReplayed)
    check("windowed app: launches as a regular (Dock) app; only a real quit terminates",
          launchActivationPolicy() == .regular)
    check("windowed app: only a real quit terminates",
          terminateShouldJustCloseWindow(realQuit: false, windowVisible: true)      // ⌘Q → close
              && !terminateShouldJustCloseWindow(realQuit: true, windowVisible: true)      // tray/logout → quit
              && !terminateShouldJustCloseWindow(realQuit: false, windowVisible: false)    // windowless → quit
              && !terminateShouldJustCloseWindow(realQuit: true, windowVisible: false))

    // Clickable checkboxes: one parser for render+toggle; the wiring flips the file on disk.
    check("checkbox: pure toggle flips [ ]↔[x] on the exact line, refuses drifted lines",
          toggledCheckboxText("- [ ] a\n- [x] b", line: 0) == "- [x] a\n- [x] b"
              && toggledCheckboxText("- [ ] a\n- [x] b", line: 1) == "- [ ] a\n- [ ] b"
              && toggledCheckboxText("plain\n- [ ] a", line: 0) == nil
              && toggledCheckboxText("- prose [ ] literal", line: 0) == nil   // drifted: not a task marker
              && toggledCheckboxText("- [ ]", line: 0) == "- [x]"             // empty task still toggles
              && toggledCheckboxText("2. [x] done", line: 0) == "2. [ ] done"
              && toggledCheckboxText("- [ ] a", line: 5) == nil
              && macrecCheckLine(URL(string: "macrec-check://7")!) == 7
              && macrecCheckLine(URL(string: "https://x.test/")!) == nil)
    let cbFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("library-cb-\(UUID().uuidString).md")
    try? "# t\n\n- [ ] draft the rollout plan\n".write(to: cbFile, atomically: true, encoding: .utf8)
    _ = LibraryWindow.shared.showSelectingForTest(cbFile)   // standalone render of the fixture
    LibraryWindow.shared.toggleCheckbox(atSourceLine: 2)
    let cbFlipped = (try? String(contentsOf: cbFile, encoding: .utf8))?.contains("- [x] draft") == true
    let cbRendered = LibraryWindow.shared.docTextForTest.contains("☑")
    LibraryWindow.shared.toggleCheckbox(atSourceLine: 0)   // "# t" is no task → the refusal must surface
    let cbRefusalSurfaced = LibraryWindow.shared.checkboxFailureForTest?.contains("changed since") == true
    try? FileManager.default.removeItem(at: cbFile)
    LibraryWindow.shared.loadFixtureForTest(libraryFixtureDays())
    check("checkbox: a click flips the file line, re-renders, and a drifted click surfaces its refusal",
          cbFlipped && cbRendered && cbRefusalSurfaced)

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
              && libraryRowSpec(fix[0].entries[1]) == LibraryRowSpec(icon: "text.bubble", tint: .neutral, text: "14:00  project kickoff", trailing: ["sparkles", "waveform"])
              && libraryRowSpec(fix[0].entries[2]) == LibraryRowSpec(icon: "text.bubble", tint: .neutral, text: "10:30  daily standup", trailing: [])
              && libraryRowSpec(fix[1].entries[0]) == LibraryRowSpec(icon: "waveform", tint: .purple, text: "17:52  (untitled)", trailing: [])
              && libraryRowSpec(fix[1].entries[1]) == LibraryRowSpec(icon: "text.bubble", tint: .neutral, text: "16:00  (untitled)", trailing: ["waveform"]))
    // Ordering: the incident was a picked day coming back NEWEST-first. Digest heads the day, then
    // earliest→latest. Tests the pure sort directly (the disk scan just calls it).
    let ordU = URL(fileURLWithPath: "/tmp/ord.md")
    let unordered = [
        LibraryEntry(day: "d", time: "14:00", title: "pm", kind: .transcript, url: ordU, summaryURL: nil, audioURL: nil),
        LibraryEntry(day: "d", time: nil, title: nil, kind: .digest, url: ordU, summaryURL: nil, audioURL: nil),
        LibraryEntry(day: "d", time: "09:00", title: "am", kind: .transcript, url: ordU, summaryURL: nil, audioURL: nil),
    ]
    check("library: a day lists the digest first, then earliest→latest (not reverse)",
          librarySortedEntries(unordered).map { $0.time ?? "digest" } == ["digest", "09:00", "14:00"])
    // Row-icon color: non-blue by rule, and the common transcript is NOT a pale secondary gray.
    check("library: row-icon tint is non-blue and the transcript icon is a strong label",
          libraryTintColor(.neutral) == .labelColor && libraryTintColor(.orange) == .systemOrange
              && libraryTintColor(.purple) == .systemPurple
              && libraryTintColor(.neutral) != .secondaryLabelColor)
    check("library: filter keeps matching rows and drops empty days",
          libraryFiltered(fix, filter: "kickoff").count == 1
              && libraryFiltered(fix, filter: "kickoff").first?.entries.count == 1
              && libraryFiltered(fix, filter: "").count == 2
              && libraryFiltered(fix, filter: "digest").first?.entries.first?.kind == .digest
              && libraryFiltered(fix, filter: "zzz").isEmpty)
    // Content (full-text) search: a term that appears ONLY in the body still surfaces the row, via the
    // injected content map — so "저 검색으로 뭘 할 수 있지?" now finds words inside transcripts/summaries.
    // Distinct URLs per entry (the real library has one file each; the shared-URL fixture cannot key content).
    let ctA = URL(fileURLWithPath: "/tmp/ct-standup.md"), ctB = URL(fileURLWithPath: "/tmp/ct-kickoff.md")
    let ctDays = [LibraryDay(day: "2026-03-02", entries: [
        LibraryEntry(day: "2026-03-02", time: "10:00", title: "standup", kind: .transcript, url: ctA, summaryURL: nil, audioURL: nil),
        LibraryEntry(day: "2026-03-02", time: "14:00", title: "kickoff", kind: .transcript, url: ctB, summaryURL: nil, audioURL: nil),
    ])]
    let contentMap = [ctB: "the migration plan and the budget were both approved"]   // "migration" only in kickoff's body
    let ctHit = libraryFiltered(ctDays, filter: "migration", content: contentMap)
    check("library: full-text search finds a term that appears only in the body, not the title",
          libraryFiltered(ctDays, filter: "migration").isEmpty                       // title-only search misses it
              && ctHit.count == 1 && ctHit.first?.entries.count == 1                  // exactly the kickoff row
              && ctHit.first?.entries.first?.title == "kickoff"
              && !libraryMetadataMatches(ctDays[0].entries[1], filter: "migration")   // it's a body-only hit
              && libraryMetadataMatches(ctDays[0].entries[1], filter: "kickoff"))     // title hit is metadata
    // No FALSE phrase match across the transcript↔summary boundary: the window joins the two bodies with a
    // newline (not a space), so a query spanning the seam must not match (review finding).
    check("library: a phrase does not match across the body-join newline",
          libraryFiltered(ctDays, filter: "plan budget", content: [ctB: "the plan\nbudget notes"]).isEmpty
              && libraryFiltered(ctDays, filter: "plan", content: [ctB: "the plan\nbudget notes"]).count == 1)
    // Snippet: the matching line, whitespace-collapsed and clipped with … around the hit — and index math
    // stays sound under a case-fold that changes byte length (was computed on a separate lowercased copy).
    check("library: a content snippet clips around the matched term (case-fold safe)",
          searchSnippet("intro line\nwe discussed the migration plan today\noutro", term: "migration")
              == "we discussed the migration plan today"
              && searchSnippet(String(repeating: "x ", count: 60) + "MIGRATION " + String(repeating: "y ", count: 60),
                               term: "migration")?.hasPrefix("… ") == true
              && searchSnippet("visit the CAFÉ downtown today", term: "café") == "visit the CAFÉ downtown today"
              && searchSnippet("Die STRASSE war voll", term: "strasse") == "Die STRASSE war voll"
              && searchSnippet("nothing here", term: "absent") == nil
              && searchSnippet("body", term: "  ") == nil)
    // Daily-only scope: keeps ONLY digest rows, drops days without one, and still composes with text.
    let txScoped = libraryFiltered(fix, filter: "", onlyKind: .transcript)
    check("library: onlyKind scope keeps digests, composes with the text filter",
          libraryFiltered(fix, filter: "", onlyKind: .digest).count == 1                     // only 2026-03-02 has a digest
              && libraryFiltered(fix, filter: "", onlyKind: .digest).first?.entries.allSatisfy { $0.kind == .digest } == true
              && libraryFiltered(fix, filter: "", onlyKind: .digest).first?.entries.count == 1  // the meetings are dropped
              && libraryFiltered(fix, filter: "kickoff", onlyKind: .digest).isEmpty            // kickoff is a meeting, not a digest
              && txScoped.count == 2                                                            // both days keep transcripts (not vacuous)
              && txScoped.flatMap(\.entries).count >= 3
              && txScoped.allSatisfy { $0.entries.allSatisfy { $0.kind == .transcript } })     // and audio-only rows are dropped
    // The WINDOW wiring: segment 1 → digest-only, 0 → all (the mapping the pure test can't see).
    let lw = LibraryWindow.shared
    lw.loadFixtureForTest(libraryFixtureDays())
    lw.setScopeForTest(1)
    let dailyScoped = lw.shownDayCountForTest == 1
    lw.setScopeForTest(0)
    let allScoped = lw.shownDayCountForTest == 2
    check("library: scope segment 1 → digest-only, 0 → all (window wiring)", dailyScoped && allScoped)
    // Layout guard, same class of check as the Settings panes: nothing collapsed, nothing overlapping.
    LibraryWindow.shared.loadFixtureForTest(libraryFixtureDays())
    let issues = LibraryWindow.shared.layoutIssues()
    check("library: no window control is collapsed or overlapping", issues.isEmpty)
    // Alignment (the day-header-shifted-right bug): the date header must sit at or LEFT of the
    // entry text — the shared cell's phantom 16pt icon gap used to push the header right of it.
    if let inset = LibraryWindow.shared.dayHeaderTextInsetForTest() {
        // The date must sit at its cell's leading edge (~2pt), NOT after a phantom 22pt icon gap.
        check("library: day-header date is flush-left in its cell (no phantom icon indent)", inset < 10)
    } else {
        check("library: a day-header row is laid out for the alignment check", false)
    }
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
        // Nothing selected, but recordings exist → the pane shows the "select one" invite (not the
        // previous doc, and not a blank half-built pane). Controls stay disabled.
        let cleared = lw.playerBarHiddenForTest && !lw.openEnabledForTest
            && lw.docTextForTest.contains("Select a recording")
        check("library: player lazy-loads with real duration, resets on row switch, names a missing file",
              audioRow && audioLayout && loaded && reset && missing && cleared)
        try? fm.removeItem(at: wav)
        // First-open transition (drives the REAL refresh path, not a pre-paint): start blank+empty like
        // build()'s pre-scan showEntry(nil), then let a rescan discover recordings with NOTHING selected.
        // The invite must appear only because refresh→applyFilter repaints it — delete that and this fails.
        lw.loadFixtureForTest([])
        lw.selectForTest(nil)
        let blankBeforeScan = lw.docTextForTest.isEmpty
        lw.setFixtureForTest(libraryFixtureDays())   // next scan sees recordings; no reselect
        lw.refreshForTest()
        let inviteAfterScan = lw.docTextForTest.contains("Select a recording")
        // A day-pick / filter that empties the VISIBLE list must NOT keep inviting a pick from an empty
        // left pane (it would contradict the "No recordings/No match" notice) — the review's P1. Drive the
        // REAL calendar button + search field so this also guards their target-action wiring.
        let pickedEmptyDay = lw.calendarPickForTest("2026-03-05")   // a real click on an empty day on the grid
        let noInviteEmptyDay = !lw.docTextForTest.contains("Select a recording")
        _ = lw.calendarClickClearForTest()   // real ✕ chip → clears the day filter
        lw.setSearchForTest("zzz-no-such-match")   // real search field + its wired filterChanged action
        let noInviteNoMatch = !lw.docTextForTest.contains("Select a recording")
        lw.setSearchForTest("")   // clears back to the full list → the invite returns
        let inviteBack = lw.docTextForTest.contains("Select a recording")
        check("library: empty-pane invite tracks the VISIBLE list (first open yes; empty day/no-match no)",
              blankBeforeScan && inviteAfterScan && pickedEmptyDay && noInviteEmptyDay && noInviteNoMatch && inviteBack)
        // The nav-highlight fix (the "dead"/무반응 nav complaint). Build a FRESH window and assert Library
        // is already filled + bold BEFORE any click — this guards build()'s own initial switchSection(.library)
        // (the first-open paint), which a click-first test would mask. Then CLICK the real nav buttons and
        // assert the selection moves. Break the startup paint, the wiring, or the style → fail.
        lw.resetWindowForTest()
        lw.loadFixtureForTest(libraryFixtureDays())
        let initialNav = lw.navHighlightForTest   // no click yet → reflects build()'s startup paint
        lw.clickNavForTest(.status)
        let statusNav = lw.navHighlightForTest
        lw.clickNavForTest(.library)
        let libNav = lw.navHighlightForTest
        check("library: Library is painted selected on open, and clicking a nav row moves the selection",
              initialNav.activeFilled && initialNav.activeBold && initialNav.othersClear
                  && statusNav.activeFilled && statusNav.activeBold && statusNav.othersClear
                  && libNav.activeFilled && libNav.activeBold && libNav.othersClear)
        // Stable-identity selection across a rescan (review Major): a summary landing on the SELECTED
        // transcript changes its value (gains summaryURL) but not its (url, kind) — the preview must
        // rebind to the fresh entry (picker now shown), not clear to the invite on a value-equality miss.
        let tURL = URL(fileURLWithPath: "/tmp/id-\(UUID().uuidString).md")
        let noSummary = LibraryDay(day: "2026-03-02", entries: [
            LibraryEntry(day: "2026-03-02", time: "11:00", title: "topic", kind: .transcript,
                         url: tURL, summaryURL: nil, audioURL: nil)])
        lw.loadFixtureForTest([noSummary])
        lw.selectForTest(noSummary.entries[0])
        let pickerHiddenNoSummary = lw.docPickerHiddenForTest   // no summary yet → picker hidden
        let withSummary = LibraryDay(day: "2026-03-02", entries: [
            LibraryEntry(day: "2026-03-02", time: "11:00", title: "topic", kind: .transcript,
                         url: tURL, summaryURL: tURL, audioURL: nil)])   // same (url, kind); summary landed
        lw.setFixtureForTest([withSummary])
        lw.refreshForTest()
        check("library: a summary landing on the selected row rebinds it (not clears) across a rescan",
              pickerHiddenNoSummary && lw.selectedURLForTest == tURL && !lw.docPickerHiddenForTest)
        // Full-text search THROUGH the window: the index reads a real file's body, so a term that lives
        // only in the body surfaces its row; and the search toggle collapses cleanly. (The pure matcher is
        // tested above; this guards the wiring — the on-disk index + the expand/collapse controls.)
        let ctURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mr-ct-\(UUID().uuidString).md")
        try? "quarterly OKR review and the migration timeline".write(to: ctURL, atomically: true, encoding: .utf8)
        lw.loadFixtureForTest([LibraryDay(day: "2026-03-02", entries: [
            LibraryEntry(day: "2026-03-02", time: "10:00", title: "sync", kind: .transcript, url: ctURL, summaryURL: nil, audioURL: nil)])])
        lw.expandSearchForTest("migration")   // only in the body, not the "sync" title
        let bodyHit = lw.shownDayCountForTest == 1 && lw.searchFieldVisibleForTest && !lw.searchToggleVisibleForTest
        lw.expandSearchForTest("zzz-absent-term")
        let missWhenAbsent = lw.shownDayCountForTest == 0
        lw.collapseSearchForTest()
        let collapsedClean = !lw.searchFieldVisibleForTest && lw.searchToggleVisibleForTest && lw.shownDayCountForTest == 1
        try? FileManager.default.removeItem(at: ctURL)
        check("library: window full-text search reads the body index and the search field collapses cleanly",
              bodyHit && missWhenAbsent && collapsedClean)
        // Month mode: the toggle swaps to the full grid (chips rendered); leaving the Library section must
        // bring the split (which HOLDS the Live/Status panes) back; the choice persists; a chip resolves
        // to its entry. Break any of these and it fails.
        lw.loadFixtureForTest(libraryFixtureDays())
        lw.clickNavForTest(.library)
        lw.setMonthModeForTest(true)
        // Month mode swaps the calendar+list for the grid (both in the left pane); the split (doc pane on
        // the right) stays up. EXACTLY 6 chips (2 days × 3) — a >= would mask a rebuild not clearing them.
        let monthOn = lw.monthModeVisibleForTest && !lw.calendarVisibleForTest && !lw.listVisibleForTest
            && lw.splitVisibleForTest && lw.monthChipCountForTest == 6
        lw.clickNavForTest(.status)   // another section hides the grid; the split (Status pane) stays up
        let splitBackOnStatus = !lw.monthModeVisibleForTest && lw.splitVisibleForTest
        lw.clickNavForTest(.library)
        let monthBackOnLibrary = lw.monthModeVisibleForTest
        // A chip fills the shared RIGHT doc pane (a side panel, not a popover) — it STAYS in Month mode and
        // selects the entry. An audio chip selects too (the doc pane's player surfaces); no dead popover.
        let chip = lw.clickMonthChipForTest(onDay: "2026-03-02")
        let chipResolves = chip != nil && lw.monthModeVisibleForTest && lw.selectedURLForTest == chip?.url
        let audio = lw.clickMonthChipForTest(onDay: "2026-03-01")   // 17:52 audio is first on 2026-03-01
        let audioResolves = audio?.kind == .audio && lw.monthModeVisibleForTest && lw.selectedURLForTest == audio?.url
        // No spill at ANY size: every day cell must CLIP its chips, so a short cell can't paint onto the
        // next row (the "UI 깨짐" the user hit; a single-size snapshot missed it). Structural, so deterministic.
        lw.setMonthModeForTest(true)
        let cellsClip = lw.monthLayoutIssuesForTest(at: NSSize(width: 1000, height: 740)) == 0
        lw.setMonthModeForTest(false)
        let monthOff = !lw.monthModeVisibleForTest && lw.calendarVisibleForTest && lw.listVisibleForTest
        check("library: Month grid shows beside the doc; a chip (incl. audio) fills the doc pane, staying in Month",
              monthOn && splitBackOnStatus && monthBackOnLibrary && chipResolves && audioResolves && monthOff && cellsClip)
        // Copy: the REAL Copy button puts the shown doc's raw text on the clipboard, and is hidden when
        // there's no doc to copy (never dead chrome). Drives the button + reads the pasteboard back.
        let copyURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mr-copy-\(UUID().uuidString).md")
        try? "# meeting\n\ndecisions: shipped".write(to: copyURL, atomically: true, encoding: .utf8)
        lw.loadFixtureForTest([LibraryDay(day: "2026-03-02", entries: [
            LibraryEntry(day: "2026-03-02", time: "10:00", title: "m", kind: .transcript, url: copyURL, summaryURL: nil, audioURL: nil)])])
        lw.selectForTest(nil)
        let copyHiddenNoDoc = lw.copyButtonHiddenForTest
        lw.clickNavForTest(.library)
        lw.selectForTest(LibraryEntry(day: "2026-03-02", time: "10:00", title: "m", kind: .transcript, url: copyURL, summaryURL: nil, audioURL: nil))
        NSPasteboard.general.clearContents()
        lw.clickCopyForTest()
        let copied = NSPasteboard.general.string(forType: .string)
        try? FileManager.default.removeItem(at: copyURL)
        check("library: Copy puts the shown doc on the clipboard and hides when there's nothing to copy",
              copyHiddenNoDoc && !lw.copyButtonHiddenForTest && copied == "# meeting\n\ndecisions: shipped")
        // NO blue: the accent recurs through NSSegmentedControl's selected segment, which an offscreen
        // snapshot never draws — so assert it STRUCTURALLY (the toggles are the monochrome MonoSegmented,
        // and no default-key blue button exists). This is the detection the eyeball QA could not do.
        check("library: no accent-blue control in the window (segmented toggles are monochrome)",
              lw.accentControlCountForTest == 0)
        LibraryWindow.shared.loadFixtureForTest(libraryFixtureDays())   // restore the rich default
    }
    // Transcript stamps: parsing, the clock→offset decision, and the seek-link scheme.
    check("transcript: stamp parsing accepts the saved shape, rejects whisper ranges/garbage",
          transcriptLineStamp("[14:01:12] Me: hi")?.clockSeconds == 50472
              && transcriptLineStamp("[00:00:00]")?.length == 10
              && transcriptLineStamp("[23:59:59] x")?.clockSeconds == 86399   // upper boundary
              && transcriptLineStamp("[14:01:12.500 --> 14:01:14.000] raw whisper") == nil
              && transcriptLineStamp("[24:00:00] x") == nil
              && transcriptLineStamp("[25:00:00] x") == nil
              && transcriptLineStamp("[14:61:00] x") == nil
              && transcriptLineStamp("14:01:12 no bracket") == nil
              && transcriptLineStamp("한[14:01:12] shifted") == nil   // multi-byte prefix, not a stamp
              && transcriptLineStamp("[hh:mm:ss] x") == nil
              && transcriptLineStamp("") == nil)
    check("transcript: clock→offset — normal, before start → 0, across midnight, long same-day kept",
          transcriptSeekOffset(lineSeconds: 50472, startSeconds: 50400) == 72     // 14:01:12 in a 14:00 file
              && transcriptSeekOffset(lineSeconds: 50398, startSeconds: 50400) == 0 // 13:59:58 stamped early
              && transcriptSeekOffset(lineSeconds: 300, startSeconds: 85800) == 900 // 23:50 file, 00:05 line
              // 08:00 file, 21:00 line: 13 h SAME-DAY is a real offset — the clamp is wrap-only
              // (review counterexample: the old unconditional ≥12 h clamp zeroed this).
              && transcriptSeekOffset(lineSeconds: 75600, startSeconds: 28800) == 46800
              && libraryStartSeconds("14:00") == 50400 && libraryStartSeconds(nil) == nil
              && libraryStartSeconds("1400") == nil && libraryStartSeconds("24:00") == nil)
    check("transcript: macrec-seek links round-trip; foreign/negative/garbage parse nil",
          macrecSeekLink(offsetSeconds: 72.4)?.absoluteString == "macrec-seek:72"
              && macrecSeekSeconds(URL(string: "macrec-seek:72")!) == 72
              && macrecSeekSeconds("macrec-seek:0") == 0
              && macrecSeekSeconds(URL(string: "https://example.com")!) == nil
              && macrecSeekSeconds("macrec-seek:-5") == nil
              && macrecSeekSeconds("macrec-seek:abc") == nil
              && macrecSeekSeconds("macrec-seek:inf") == nil
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
        // A stamped line with a "|" followed by a separator-looking line must STAY a seek line —
        // the table branch once ran first and swallowed it (review counterexample).
        let piped = MarkdownRender.render("[14:01:12] Me: status | update\n|---|---|", transcriptStart: 50400)
        check("markdown: transcript stamps become macrec-seek links only with a start clock",
              linkAt(linked, "[14:01:12]")?.absoluteString == "macrec-seek:72"
                  && linkAt(linked, "[13:59:58]")?.absoluteString == "macrec-seek:0"
                  && linked.string.contains("Me: kickoff begins")
                  && linkAt(MarkdownRender.render(tmd), "[14:01:12]") == nil
                  && linkAt(piped, "[14:01:12]")?.absoluteString == "macrec-seek:72"
                  && piped.string.contains("status | update"))
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
        let edge = transcriptCues("[10:00:05] Me: a\n[10:00:05] Them: b\nprose\n[10:00:07]   \n[10:00:20] Me: c",
                                  startSeconds: 36000)
        let anchored = transcriptCues("[10:00:05] Me: a\n[10:00:09] Them: b", startSeconds: nil)
        let wrapped = transcriptCues("[23:59:58] Me: a\n[00:00:06] Them: b", startSeconds: 85800)
        check("export: cue edges — same-second keeps 1 s, prose/empty lines carry no cue, nil start anchors at 0, midnight wraps",
              edge == [TranscriptCue(start: 5, end: 6, text: "Me: a"),
                       TranscriptCue(start: 5, end: 20, text: "Them: b"),
                       TranscriptCue(start: 20, end: 25, text: "Me: c")]
                  && anchored.first?.start == 0 && anchored.last?.start == 4
                  && wrapped == [TranscriptCue(start: 598, end: 606, text: "Me: a"),
                                 TranscriptCue(start: 606, end: 611, text: "Them: b")])
        // The SRT/VTT of a stamp-less file would be empty — the panel must refuse, not write it.
        check("export: subtitle formats refuse a stamp-less document; markdown/plain never do",
              transcriptExportIssue("just prose, no stamps", format: .srt) != nil
                  && transcriptExportIssue("just prose, no stamps", format: .vtt) != nil
                  && transcriptExportIssue("just prose, no stamps", format: .markdown) == nil
                  && transcriptExportIssue("just prose, no stamps", format: .plainText) == nil
                  && transcriptExportIssue("[10:00:05] Me: a", format: .srt) == nil
                  && subtitleClock(.nan, millisSeparator: ",") == "00:00:00,000")   // garbage must not trap
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
        // Fenced content is DATA — its markers survive verbatim (review: they were being stripped);
        // a pathological long line skips the quadratic link regex instead of beachballing (13.8 s
        // at 40k chars when this guard was missing).
        let fenced = transcriptToPlainText("```\n# code heading\n> code quote\n**still code**\n```")
        let flood = String(repeating: "[", count: 8000)
        let floodStart = Date()
        let floodOut = transcriptToPlainText(flood)
        check("export: plain text keeps fenced content verbatim and caps the regex line length",
              fenced.contains("# code heading") && fenced.contains("> code quote")
                  && fenced.contains("**still code**")
                  && floodOut.contains(flood)   // returned untouched…
                  && Date().timeIntervalSince(floodStart) < 1.0)   // …and fast
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
    // Feedback for a run already in flight (or its failure) outranks the prefs gate — flipping the
    // mode mid-run must not vanish the spinner or the failure reason (review finding).
    check("library: summary slot — running/failed feedback survives a prefs flip",
          librarySummarySlot(kind: .transcript, hasInvocation: false, writesSummaryFile: false,
                             hasSummary: false, phase: .running)
              == LibrarySummarySlot(buttonTitle: nil, spinning: true, status: "Summarizing…")
              && librarySummarySlot(kind: .transcript, hasInvocation: false, writesSummaryFile: false,
                                    hasSummary: true, phase: .failed("not logged in"))
              == LibrarySummarySlot(buttonTitle: nil, spinning: false,
                                    status: "Summary failed — not logged in")
              && librarySummarySlot(kind: .digest, hasInvocation: false, writesSummaryFile: false,
                                    hasSummary: false, phase: .running).spinning == false)
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
        // A run: spinner while running; success RESCANS (the fixture gains its summary mid-run,
        // like the real disk would) and re-finds the user's row — proving reselect, not merely
        // that the selection was never at risk (review: the old fixture never changed).
        SummaryStatus.shared.resetForTest()
        var noSum = libraryFixtureDays()
        noSum[0].entries[1].summaryURL = nil
        lw.setFixtureForTest(noSum)
        lw.refresh()
        lw.selectForTest(noSum[0].entries[1])
        let readyBefore = lw.rerunButtonTitleForTest == "Summarize"
        var ranCmd: String?
        lw.runCommandForTest = { cmd, done in
            ranCmd = cmd
            lw.setFixtureForTest(libraryFixtureDays())   // the summary "appears on disk"
            done(0)
        }
        lw.rerunClickForTest()
        let spinning = lw.rerunSpinningForTest && lw.rerunButtonTitleForTest == nil
            && lw.rerunStatusForTest == "Summarizing…"
        let layoutRunning = lw.layoutIssues().isEmpty   // the spinner is walked by the guard now
        pump { !lw.rerunSpinningForTest }
        let succeeded = lw.rerunButtonTitleForTest == "Re-run summary"   // fresh entry HAS a summary
            && lw.rerunStatusForTest == nil
            && lw.openEnabledForTest   // …and the selection survived the rescan via reselect
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
        check("library: re-run summary — spinner while running, refresh re-finds the row, failure names the reason",
              readyBefore && spinning && layoutRunning && succeeded && failed)
        // The ENGINE's in-flight run for the same file parks the button — one registry, no second
        // racing run onto the same .partial files (review P0).
        SummaryStatus.shared.resetForTest()
        lw.resetRerunForTest()
        SummaryStatus.shared.beginRun(path: fix[0].entries[1].url.path)
        lw.selectForTest(fix[0].entries[1])
        let engineParked = lw.rerunSpinningForTest && lw.rerunButtonTitleForTest == nil
        var racedDuringEngineRun = false
        lw.runCommandForTest = { _, done in racedDuringEngineRun = true; done(0) }
        lw.rerunClickForTest()   // must refuse — the engine already owns this file
        SummaryStatus.shared.endRun(path: fix[0].entries[1].url.path)
        lw.selectForTest(fix[0].entries[1])
        let engineDone = lw.rerunButtonTitleForTest == "Re-run summary" && !lw.rerunSpinningForTest
        // An engine failure recorded in SummaryStatus surfaces here too — an overnight "Summary
        // failed" must be visible in the Library, not only as a long-dismissed notification.
        SummaryStatus.shared.failed(fix[0].entries[1].url.lastPathComponent, at: Date(), reason: "no runner")
        lw.selectForTest(fix[0].entries[1])
        let engineFailShown = lw.rerunStatusForTest == "Summary failed — no runner"
        check("library: the engine's run parks the button; its failure surfaces in the header",
              engineParked && !racedDuringEngineRun && engineDone && engineFailShown)
        lw.runCommandForTest = nil
        lw.resetRerunForTest()
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
