import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - pure decisions (selftested)

/// The section header for a day: Today/Yesterday read faster than dates for the two days that matter.
func libraryDayLabel(day: String, today: String, yesterday: String) -> String {
    day == today ? "Today — \(day)" : day == yesterday ? "Yesterday — \(day)" : day
}

/// One row's visual spec: a leading KIND icon (digest / meeting / audio-only read apart at a
/// glance), the text, and trailing status icons ("summarized" sparkles, "audio kept" waveform).
/// Pure so the icon/text decisions are selftested; the cell just materializes SF Symbols.
struct LibraryRowSpec: Equatable {
    enum Tint: String { case orange, purple, neutral } // semantic — the cell maps to NSColors
    var icon: String // SF Symbol name — the entry's kind
    var tint: Tint
    var text: String
    var trailing: [String] // SF Symbol names — what else exists for this entry
}

func libraryRowSpec(_ e: LibraryEntry) -> LibraryRowSpec {
    if e.kind == .digest {
        return LibraryRowSpec(icon: "newspaper", tint: .orange, text: "Daily digest", trailing: [])
    }
    let text = "\(e.time ?? "--:--")  \(e.title ?? "(untitled)")"
    if e.kind == .audio { return LibraryRowSpec(icon: "waveform", tint: .purple, text: text, trailing: []) }
    var trailing: [String] = []
    if e.summaryURL != nil { trailing.append("sparkles") }
    if e.audioURL != nil { trailing.append("waveform") }
    return LibraryRowSpec(icon: "text.bubble", tint: .neutral, text: text, trailing: trailing)
}

/// Tint → row-icon color. Non-blue by rule (the user reads blue as too loud), and NOT washed out:
/// a full-strength label for the common transcript so its icon never goes pale, warm accents for the
/// two special kinds. Pure so the palette is selftested against a reintroduced blue.
func libraryTintColor(_ t: LibraryRowSpec.Tint) -> NSColor {
    switch t {
    case .orange: return .systemOrange
    case .purple: return .systemPurple
    case .neutral: return .labelColor
    }
}

/// mm:ss (or h:mm:ss) for the player clock. Pure + selftested.
func libraryClock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let s = Int(seconds.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

/// Where the library reads from — the same resolution the pipeline writes with: an empty summary
/// dir means "next to the transcripts", an empty digest dir means "alongside the summaries"
/// (dailyDigestOutputPath's rule). Pure so the fallback chain is testable.
func libraryRoots(transcripts: String, summaryOut: String, dailyOut: String, audioDir: String)
    -> (transcripts: String, summaries: String, daily: String, audio: String) {
    // Expand "~" symmetrically with the WRITE side (summaryOutputPath / dailyDigestOutputPath both
    // expandingTildeInPath): a typed "~/sums" dir would otherwise scan a literal "~" folder, find no
    // summaries, and the tray "summary:" click would dead-end on a file it wrote to the real path.
    func expand(_ p: String) -> String { p.isEmpty ? p : (p as NSString).expandingTildeInPath }
    let s = summaryOut.isEmpty ? transcripts : summaryOut
    let d = dailyOut.isEmpty ? s : dailyOut
    return (expand(transcripts), expand(s), expand(d), expand(audioDir))
}

// MARK: - the Library window (the desktop app's first surface)

/// What got transcribed and summarized, by day — the tray menu shows only the LAST result, and
/// answering "what did macrec catch today?" used to mean digging through Finder. Left: days and
/// entries; right: the selected transcript/summary, with Open / Reveal for the real file.
final class LibraryWindow: NSObject, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSSplitViewDelegate, AVAudioPlayerDelegate, NSTextViewDelegate, NSSearchFieldDelegate {
    static let shared = LibraryWindow()
    private var window: NSWindow?
    private let outline = NSOutlineView()
    // ── main-window sections (DESIGN-main-window.md): the sidebar routes Live / Library / Status ──
    enum MainSection: Int { case live = 0, library = 1, status = 2 }
    private(set) var section: MainSection = .library
    private var navButtons: [NSButton] = []
    private let livePane = NSStackView()
    private let liveText = NSTextView()
    private let liveHint = NSTextField(labelWithString: "Live Captions mirror — start/stop from the tray; the floating overlay stays available as a second screen.")
    private let statusPane = NSStackView()
    private var statusActions: [HealthAction] = []
    private var statusTimer: Timer?
    /// Wired by the app: the same live health sample + action routing the Status window uses.
    var healthSample: (() -> HealthInputs)?
    var onHealthAction: ((HealthAction) -> Void)?

    private let searchField = NSSearchField()
    private let searchToggle = NSButton()   // magnifier; expands the field on click, collapses when empty
    private let scopePicker = NSSegmentedControl()   // All | Daily (digests only)
    private let viewModePicker = NSSegmentedControl()   // List | Month — the two library presentations
    private let monthView = MonthCalendarView()   // the big Calendar.app-style grid (Month mode)
    private var monthMode = false   // false = the list+compact-calendar; true = the full month grid
    private let entryPopover = NSPopover()   // a chip's transcript shown in place (Month mode)
    private var libSplit: NSSplitView!   // the list/doc split — hidden while the month grid is up
    private let textView = NSTextView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let docPicker = NSSegmentedControl(labels: ["Summary", "Transcript"],
                                               trackingMode: .selectOne, target: nil, action: nil)
    private let openBtn = NSButton(title: "Open", target: nil, action: nil)
    private let revealBtn = NSButton(title: "Reveal", target: nil, action: nil)   // in Finder (tooltip); short to leave the title room
    private let deleteBtn = NSButton(title: "Delete…", target: nil, action: nil)   // confirm → Trash the entry + its files
    private let exportBtn = NSButton(title: "Export Transcript…", target: nil, action: nil)
    // Transcript-actions row (its own row — squeezed into the header strip they crushed the title):
    // Export + the re-run slot (button OR spinner+label), derived in applyHeaderActions (one decision).
    private var summaryBar: NSStackView!
    private var headBar: NSStackView!   // header row (title + doc picker + Open/Reveal/Delete)
    private let rerunBtn = NSButton(title: "Re-run summary", target: nil, action: nil)
    private let rerunSpinner = NSProgressIndicator()
    private let rerunStatus = NSTextField(labelWithString: "")
    private var rerunPhase: [URL: LibraryRerunPhase] = [:]
    private var exportPanel: NSSavePanel?
    private let exportFormatPopup = NSPopUpButton()
    private var lastExportFormat = 0 // the format popup remembers the user's pick across exports
    private let emptyLabel = NSTextField(wrappingLabelWithString:
        "Nothing here yet — transcripts appear as meetings are recorded.")
    // Audio player bar — exists only while the selected entry has audio.
    private var playerBar: NSStackView!
    private let playBtn = NSButton(title: "▶", target: nil, action: nil)
    private let seekSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let clockLabel = NSTextField(labelWithString: "--:-- / --:--")
    private var player: AVAudioPlayer?
    private var playerTimer: Timer?

    private var allDays: [LibraryDay] = []
    // Full-text search index, keyed by entry URL. Refreshed OFF the main thread (a big library would
    // otherwise beach-ball on the first keystroke), incrementally by file mtime so a focus-gain or an
    // unchanged rescan costs nothing. `orig` feeds the result snippet from memory (no per-row disk read).
    private struct IndexedBody { let sig: String; let lower: String; let orig: String }
    private var contentIndex: [URL: IndexedBody] = [:]
    private var contentLower: [URL: String] = [:] // derived lower-only map handed to the pure filter
    private var contentIndexRefreshing = false
    private var rowSnippetCache: [URL: String] = [:] // per-reload snippets — heightOfRowByItem + viewFor share one scan
    private var shownDays: [LibraryDay] = []
    private var fixtureDays: [LibraryDay]? // test/snapshot data — nil means scan the real folders
    private var selected: LibraryEntry?
    private var standaloneURL: URL? // a file rendered directly (tray fallback: on disk but not indexed)
    // The calendar sidebar (user ask): clicking a day filters the list to it; nil = every day.
    private let calendarView = LibraryCalendarView()
    private var selectedDay: String?

    var isVisible: Bool { window?.isVisible ?? false }
    func closeWindow() { window?.performClose(nil) }

    func show() {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        if section == .status, statusTimer == nil { switchSection(.status) }   // reopen restarts the tick
    }

    /// Open the window on `target` (a summary or digest file) and show it — the tray "summary:" row's
    /// in-app destination, replacing the old reveal-in-Finder. An INDEXED target selects its row and the
    /// Summary view; a target that's on disk but not indexed (orphaned summary, custom-named digest) is
    /// rendered directly — still in-app, never bouncing to Finder (user request). Never a dead click.
    func show(selecting target: URL) {
        show()   // makeKeyAndOrderFront + refresh() → allDays populated
        if !selectIndexed(target), FileManager.default.fileExists(atPath: target.path) {
            renderStandalone(target)
        }
    }

    /// Select the indexed row for `target` (clearing any filter FIRST so reselect's row exists) and show
    /// its Summary. Returns false — WITHOUT touching the filter — when the target isn't indexed, so a
    /// miss leaves the user's browsing place. Shared by `show(selecting:)` and its test hook, so the
    /// selftest drives this real logic rather than a mirror (test-honesty).
    private func selectIndexed(_ target: URL) -> Bool {
        guard let hit = libraryEntryToSelect(days: allDays, target: target) else { return false }
        searchField.stringValue = ""; scopePicker.selectedSegment = 0
        selectedDay = nil   // an active calendar day-filter would hide the target's row too
        calendarView.syncSelection(nil)   // the view's highlight must follow, or it lies (review P1)
        applyFilter()   // unfiltered outline so reselect finds the row
        reselect(url: hit.url, kind: hit.kind)
        return true
    }

    /// Render a file NOT in the index directly in the right pane — the tray fallback when a summary's
    /// transcript was deleted/renamed or a custom-named digest isn't a library row. In-app markdown, so
    /// the user still sees the note (Open/Reveal act on this file via currentDocURL's standalone branch).
    private func renderStandalone(_ url: URL) {
        stopPlayback()
        selected = nil
        standaloneURL = url
        headerLabel.stringValue = url.deletingPathExtension().lastPathComponent
        headerLabel.toolTip = url.path
        headBar.isHidden = false      // a standalone render IS content — the strip returns
        summaryBar.isHidden = false
        docPicker.isHidden = true
        playerBar.isHidden = true
        openBtn.isEnabled = true
        revealBtn.isEnabled = true
        deleteBtn.isEnabled = false   // a standalone-rendered file has no indexed entry / related files to delete
        applyHeaderActions()
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            let text = String(decoding: data.prefix(2_000_000), as: UTF8.self)
            textView.textStorage?.setAttributedString(MarkdownRender.render(text, baseURL: url, transcriptStart: nil))
            textView.scrollToBeginningOfDocument(nil)
        } else {
            setPlainDoc("(could not read \(url.path))")
        }
    }

    /// Re-scan sources. Called on open, on focus, and when the engine saves a transcript — the
    /// index is a snapshot, and these are the events that invalidate it.
    func refresh() {
        allDays = fixtureDays ?? scanReal()
        // The content index is NOT wiped here: refreshContentIndexAsync reconciles it by mtime, so an
        // unchanged rescan or a focus-gain re-reads nothing (only changed/new files, dropping vanished).
        // Prune re-run state for files the scan no longer sees (deleted/renamed) — in-flight runs
        // keep their entry so a completion can still land its failure reason.
        let urls = Set(allDays.flatMap(\.entries).map(\.url))
        rerunPhase = rerunPhase.filter { $0.value == .running || urls.contains($0.key) }
        // The calendar mirrors the scan: recorded days light up. The month FOLLOWS the newest data
        // until the user pages with ‹ › — then their browsing owns it (a new recording must move an
        // auto-tracking grid, but must never snap a browsed month back; review finding).
        let today = Self.dayString(Date())
        let month = calendarView.userNavigated
            ? calendarView.month : String((allDays.first?.day ?? today).prefix(7))
        calendarView.load(month: month, contentDays: Set(allDays.map(\.day)),
                          selectedDay: selectedDay, today: today)
        applyFilter()
        applyHeaderActions()   // a rescan may reflect saved prefs / a finished run — re-derive once
        if monthMode, section == .library { loadMonth() }   // keep the grid in sync with new recordings
    }

    /// Engine hook: a transcript/summary just landed. Refresh only if the user is looking.
    func noteLibraryChanged() {
        if let w = window, w.isVisible { refresh() }
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    private func scanReal() -> [LibraryDay] {
        let roots = libraryRoots(
            transcripts: Pref.str(Pref.txtDir, "MR_TRANSCRIPTS_DIR",
                                  NSHomeDirectory() + "/Documents/macrec/transcripts"),
            summaryOut: Pref.explicit(Pref.summaryOut, "MR_SUMMARY_OUT"),
            dailyOut: Pref.explicit(Pref.dailyDigestOut, "MR_DAILY_DIGEST_OUT"),
            audioDir: Pref.str(Pref.audioDir, "MR_AUDIO_DIR", ""))
        // limitDays 3650, not the scan's 90 default: the calendar can page YEARS back, and a month
        // that has recordings must never render as empty just because it fell off a silent cap.
        return scanLibrary(transcriptsDir: URL(fileURLWithPath: roots.transcripts),
                           summaryDir: URL(fileURLWithPath: roots.summaries),
                           dailyDir: URL(fileURLWithPath: roots.daily),
                           audioDir: roots.audio.isEmpty ? nil : URL(fileURLWithPath: roots.audio),
                           limitDays: 3650)
    }

    // MARK: build

    private func build() {
        let w = EditKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        w.title = "macrec library"
        // No visible title bar (modern desktop-app look): the content runs to the top edge and the
        // traffic lights float over it; the toolbar row leaves a draggable strip clear of them.
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.minSize = NSSize(width: 640, height: 360)
        // The 1160×720 default is a suggestion — the user's own size/position wins across opens.
        w.setFrameAutosaveName("libraryWindow")
        let content = NSView()

        // Search collapses to a magnifier button (the always-wide field wasted the whole top row);
        // clicking expands the field + focuses it, and it collapses again when left empty.
        searchToggle.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        searchToggle.isBordered = false
        searchToggle.bezelStyle = .inline
        searchToggle.setAccessibilityLabel("Search")
        searchToggle.target = self
        searchToggle.action = #selector(toggleSearch)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search titles & contents"
        searchField.sendsSearchStringImmediately = true
        searchField.isHidden = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(filterChanged)

        // Scope: All vs Daily digests only — the fastest way to answer "what did each day boil down
        // to?" without scrolling past every meeting. Composes with the text filter.
        scopePicker.segmentCount = 2
        scopePicker.setLabel("All", forSegment: 0)
        scopePicker.setLabel("Daily", forSegment: 1)
        scopePicker.selectedSegment = 0
        scopePicker.segmentStyle = .texturedRounded
        scopePicker.target = self
        scopePicker.action = #selector(filterChanged)
        scopePicker.setContentHuggingPriority(.required, for: .horizontal)

        let refreshBtn = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        refreshBtn.bezelStyle = .rounded
        // View mode: the compact list vs the big month grid — the two presentations the user asked for.
        viewModePicker.segmentCount = 2
        viewModePicker.setLabel("List", forSegment: 0)
        viewModePicker.setLabel("Month", forSegment: 1)
        viewModePicker.segmentStyle = .texturedRounded
        viewModePicker.selectedSegment = 0
        viewModePicker.target = self
        viewModePicker.action = #selector(viewModeChanged)
        viewModePicker.setContentHuggingPriority(.required, for: .horizontal)
        // Search lives at the RIGHT end (Calendar.app's placement): a magnifier that expands into a field
        // in place — the toggle hides while the field is up, so the field's own magnifier isn't doubled.
        let bar = NSStackView(views: [viewModePicker, scopePicker, refreshBtn, NSView(), searchField, searchToggle])
        bar.orientation = .horizontal
        bar.spacing = 8
        // Left inset clears the traffic lights (fullSizeContentView); top inset leaves a drag strip.
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 78, bottom: 6, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false
        searchToggle.setContentHuggingPriority(.required, for: .horizontal)
        // The field holds a compact right-anchored width; the flexible spacer before it takes the slack.
        searchField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        // Left: the day/entry outline.
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        col.title = "Recordings"
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .medium
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowSelected)
        let leftScroll = NSScrollView()
        leftScroll.documentView = outline
        leftScroll.hasVerticalScroller = true
        // The calendar rides ABOVE the list in the left pane; its pick becomes the day filter.
        calendarView.onPick = { [weak self] day in
            guard let self else { return }
            selectedDay = day
            applyFilter()
        }
        // Sidebar nav: three peer destinations (1Password's Watchtower/All-Items shape). Selecting
        // one swaps the right-hand detail; the day tree below stays the Library's navigation.
        var navSpecs: [(String, String, MainSection)] = [
            ("rectangle.stack", "Library", .library),
            ("heart.text.square", "Status", .status),
        ]
        // Live Captions only exists on macOS 26 — offering the row earlier would be a dead pane.
        if #available(macOS 26, *) { navSpecs.insert(("waveform", "Live Captions", .live), at: 0) }
        let nav = NSStackView()
        nav.orientation = .vertical
        nav.spacing = 2
        nav.edgeInsets = NSEdgeInsets(top: 34, left: 10, bottom: 6, right: 10)
        for (sym, label, sec) in navSpecs {
            let b = NSButton(title: "  " + label, target: self, action: #selector(navTapped(_:)))
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: label)
            b.imagePosition = .imageLeading
            b.isBordered = false
            b.contentTintColor = .labelColor
            b.font = .systemFont(ofSize: 13, weight: .medium)
            b.alignment = .left
            b.tag = sec.rawValue
            b.wantsLayer = true
            b.layer?.cornerRadius = 5
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            navButtons.append(b)
            nav.addArrangedSubview(b)
            b.leadingAnchor.constraint(equalTo: nav.leadingAnchor, constant: 10).isActive = true
            b.trailingAnchor.constraint(equalTo: nav.trailingAnchor, constant: -10).isActive = true
        }

        let left = NSStackView(views: [nav, calendarView, leftScroll])
        left.orientation = .vertical
        left.spacing = 0
        nav.leadingAnchor.constraint(equalTo: left.leadingAnchor).isActive = true
        nav.trailingAnchor.constraint(equalTo: left.trailingAnchor).isActive = true
        calendarView.leadingAnchor.constraint(equalTo: left.leadingAnchor).isActive = true
        calendarView.trailingAnchor.constraint(equalTo: left.trailingAnchor).isActive = true
        leftScroll.leadingAnchor.constraint(equalTo: left.leadingAnchor).isActive = true
        leftScroll.trailingAnchor.constraint(equalTo: left.trailingAnchor).isActive = true

        // Right: header (what's selected + actions) over the document text.
        headerLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        headerLabel.lineBreakMode = .byTruncatingTail
        docPicker.target = self
        docPicker.action = #selector(docPicked)
        openBtn.target = self
        openBtn.action = #selector(openDoc)
        revealBtn.target = self
        revealBtn.action = #selector(revealDoc)
        revealBtn.toolTip = "Reveal in Finder"
        exportBtn.target = self
        exportBtn.action = #selector(exportClicked)
        exportBtn.toolTip = "Save the transcript as Markdown, plain text, SRT or VTT"
        rerunBtn.target = self
        rerunBtn.action = #selector(rerunClicked)
        deleteBtn.target = self
        deleteBtn.action = #selector(deleteClicked)
        deleteBtn.toolTip = "Move this recording (transcript, summary, and audio) to the Trash"
        for b in [openBtn, revealBtn, exportBtn, rerunBtn, deleteBtn] { b.bezelStyle = .rounded }
        rerunSpinner.style = .spinning
        rerunSpinner.controlSize = .small
        rerunSpinner.isDisplayedWhenStopped = false
        rerunStatus.font = NSFont.systemFont(ofSize: 11)
        rerunStatus.textColor = .secondaryLabelColor
        rerunStatus.lineBreakMode = .byTruncatingTail
        rerunStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let head = NSStackView(views: [headerLabel, NSView(), docPicker, openBtn, revealBtn, deleteBtn])
        headBar = head
        head.orientation = .horizontal
        head.spacing = 8
        head.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 6, right: 10)
        headerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryBar = NSStackView(views: [rerunBtn, exportBtn, rerunSpinner, rerunStatus, NSView()])
        summaryBar.orientation = .horizontal
        summaryBar.spacing = 8
        summaryBar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 6, right: 10)

        textView.isEditable = false
        // Mono links: NSTextView paints .link runs with its own attributes (default accent blue),
        // overriding the attributed string — pin them to underlined label gray here.
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.isSelectable = true
        textView.delegate = self   // intercepts macrec-seek: stamp clicks (clickedOnLink below)
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let rightScroll = NSScrollView()
        rightScroll.documentView = textView
        rightScroll.hasVerticalScroller = true

        // Audio player bar — between the header and the document.
        playBtn.target = self
        playBtn.action = #selector(togglePlay)
        playBtn.bezelStyle = .rounded
        playBtn.setContentHuggingPriority(.required, for: .horizontal)
        // Deliberate non-gate: playback stays available while recording (headphone users), but the
        // acoustic loop (speakers → mic → live segment) deserves a warning where the click happens.
        playBtn.toolTip = "While a recording is running, speaker playback can leak into the mic — use headphones."
        seekSlider.target = self
        seekSlider.action = #selector(seekChanged)
        clockLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        clockLabel.textColor = .secondaryLabelColor
        clockLabel.setContentHuggingPriority(.required, for: .horizontal)
        playerBar = NSStackView(views: [playBtn, seekSlider, clockLabel])
        playerBar.orientation = .horizontal
        playerBar.spacing = 8
        playerBar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 6, right: 10)
        seekSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Live pane: a read-only mirror of the overlay's stream, same typography, plus the hint.
        liveText.isEditable = false
        liveText.drawsBackground = false
        liveText.textContainerInset = NSSize(width: 16, height: 12)
        liveText.isVerticallyResizable = true
        liveText.isHorizontallyResizable = false
        liveText.autoresizingMask = [.width]
        liveText.textContainer?.widthTracksTextView = true
        let liveScroll = NSScrollView()
        liveScroll.documentView = liveText
        liveScroll.hasVerticalScroller = true
        liveScroll.drawsBackground = false
        liveHint.font = .systemFont(ofSize: 11)
        liveHint.textColor = .secondaryLabelColor
        liveHint.lineBreakMode = .byWordWrapping
        liveHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let liveHintBar = NSStackView(views: [liveHint])
        liveHintBar.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 4, right: 16)
        livePane.orientation = .vertical
        livePane.spacing = 0
        livePane.addArrangedSubview(liveHintBar)
        livePane.addArrangedSubview(liveScroll)
        liveHintBar.setContentHuggingPriority(.required, for: .vertical)
        // Status pane: the SAME health rows the Status window renders (shared factory), embedded.
        statusPane.orientation = .vertical
        statusPane.alignment = .leading
        statusPane.spacing = 2
        statusPane.edgeInsets = NSEdgeInsets(top: 34, left: 16, bottom: 12, right: 16)

        let right = NSStackView(views: [head, summaryBar, playerBar, rightScroll, livePane, statusPane])
        right.orientation = .vertical
        right.spacing = 0
        right.distribution = .fill
        livePane.isHidden = true
        statusPane.isHidden = true
        head.setContentHuggingPriority(.required, for: .vertical)
        summaryBar.setContentHuggingPriority(.required, for: .vertical)
        playerBar.setContentHuggingPriority(.required, for: .vertical)

        let split = NSSplitView()
        libSplit = split
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        // Classic (autoresizing) pane sizing, NOT autolayout — for BOTH panes: with anchored
        // arranged subviews the split view logged an ambiguous-layout warning and refused full
        // divider dragging (observed live the first night). Pane minimums live in the delegate.
        left.translatesAutoresizingMaskIntoConstraints = true
        left.autoresizingMask = [.width, .height]
        right.translatesAutoresizingMaskIntoConstraints = true
        right.autoresizingMask = [.width, .height]
        split.delegate = self
        split.autosaveName = "libraryDivider"

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true

        // The month grid fills the same area as the split; only one is visible at a time (updateModeVisibility).
        monthView.isHidden = true
        monthView.onPickEntry = { [weak self] entry, from in
            // Audio has no transcript to render in a popover — drop to the list and select it so the
            // player bar surfaces; a transcript/digest reads in place.
            guard let self else { return }
            if entry.kind == .audio { openEntryInList(entry) } else { showEntryPopover(entry, from: from) }
        }
        monthView.onPickDay = { [weak self] day in self?.dropToDayList(day) }

        content.addSubview(bar)
        content.addSubview(split)
        content.addSubview(monthView)
        content.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: bar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            monthView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            monthView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            monthView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            monthView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        w.contentView = content
        content.layoutSubtreeIfNeeded()
        split.setPosition(300, ofDividerAt: 0)   // list ≈ a third, document gets the rest
        window = w
        showEntry(nil)   // the right pane starts EMPTY — no ghost picker/player before a selection
        monthMode = Pref.d.string(forKey: Pref.libraryViewMode) == "month"   // restore the saved presentation
        viewModePicker.selectedSegment = monthMode ? 1 : 0
        switchSection(.library)   // paint the default nav selection now — an unhighlighted Library read as dead
    }

    // MARK: data → view

    @objc private func navTapped(_ sender: NSButton) {
        switchSection(MainSection(rawValue: sender.tag) ?? .library)
    }

    /// Swap the detail to the picked section. The Library's own subviews keep their internal
    /// hidden/shown state; the section toggle only overlays on top of it.
    func switchSection(_ new: MainSection) {
        section = new
        for b in navButtons {
            let on = b.tag == new.rawValue
            // A FIXED mid-gray, not a dynamic catalog color: a layer's cgColor is resolved once and
            // never re-adapts, so a dynamic color froze to build-time appearance and showed a dark pill
            // in light mode. A 0.12 label alpha was also invisible in light, so the active section read
            // as unselected ("무반응"). This gray reads on both backgrounds; bold marks the active row.
            b.layer?.backgroundColor = on ? NSColor.gray.withAlphaComponent(0.28).cgColor : nil
            b.font = .systemFont(ofSize: 13, weight: on ? .semibold : .medium)
        }
        let lib = new == .library
        livePane.isHidden = new != .live
        statusPane.isHidden = new != .status
        // Library chrome hides wholesale outside its section; inside it, showEntry state rules.
        headBar.isHidden = !lib || selected == nil && standaloneURL == nil
        summaryBar.isHidden = headBar.isHidden
        playerBar.isHidden = !lib || selected?.audioURL == nil
        if let scroll = textView.enclosingScrollView { scroll.isHidden = !lib }
        if lib { applyHeaderActions() }
        if new == .status { rebuildStatusPane() }
        statusTimer?.invalidate(); statusTimer = nil
        if new == .status {   // live mic %/verdicts, like the Status window's own 1 Hz tick
            let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self, section == .status,
                      window?.isVisible == true || fixtureDays != nil else { return }
                rebuildStatusPane()
            }
            RunLoop.main.add(t, forMode: .common)
            statusTimer = t
        }
        if new == .live, let pending = pendingLiveMirror {
            pendingLiveMirror = nil
            liveMirror(pending)   // replay the caption that arrived while another section was up
        }
        updateModeVisibility()
    }

    /// One decision for List-vs-Month: the month grid only ever shows inside the Library section; the
    /// split (which HOLDS the Live/Status panes) must reappear the moment another section is picked.
    private func updateModeVisibility() {
        let showMonth = section == .library && monthMode
        monthView.isHidden = !showMonth
        libSplit.isHidden = showMonth
        viewModePicker.isHidden = section != .library   // the toggle only applies to the Library
        if showMonth { emptyLabel.isHidden = true; loadMonth() }   // the grid is its own empty state
    }

    /// The one place mode is set: flips the flag, the segmented control, and the persisted pref together
    /// so viewModeChanged and dropToList can't drift.
    private func setMonthMode(_ on: Bool) {
        monthMode = on
        viewModePicker.selectedSegment = on ? 1 : 0
        Pref.d.set(on ? "month" : "list", forKey: Pref.libraryViewMode)
    }

    @objc private func viewModeChanged() {
        setMonthMode(viewModePicker.selectedSegment == 1)
        entryPopover.close()
        updateModeVisibility()
    }

    /// Feed the month grid: ALL recordings grouped by day (the grid IS the navigation, not a filtered
    /// view), on the newest-data month unless the user has paged. A snapshot re-taken on every change.
    private func loadMonth() {
        let today = Self.dayString(Date())
        let month = monthView.userNavigated ? monthView.month : String((allDays.first?.day ?? today).prefix(7))
        monthView.load(month: month, entriesByDay: entriesByDayMap(allDays), today: today)
    }

    /// The popover's read-only document: render the summary (or transcript), then strip the interactive
    /// checkbox/seek links (macrec-check:// / macrec-seek://) — the popover has no delegate, so a click
    /// would be a silent dead-end, and toggling here would hit the wrong file. Glyphs/text stay. Read is
    /// capped + lenient with a visible truncation note, matching loadDoc (a stray byte must not fail it).
    private func popoverDoc(for e: LibraryEntry) -> NSAttributedString {
        let src = e.summaryURL ?? e.url
        let md: String
        if let data = try? Data(contentsOf: src, options: .mappedIfSafe) {
            let capped = data.prefix(2_000_000)
            // A neutral notice — the popover has no "Open" (Month mode hides that pane), so don't promise it.
            md = String(decoding: capped, as: UTF8.self)
                + (data.count > capped.count ? "\n\n… (preview truncated)" : "")
        } else {
            md = "(could not read \(src.lastPathComponent))"
        }
        let rendered = NSMutableAttributedString(attributedString: MarkdownRender.render(md, baseURL: src.deletingLastPathComponent()))
        rendered.removeAttribute(.link, range: NSRange(location: 0, length: rendered.length))
        return rendered
    }

    /// Anchored to the chip so the user reads it without leaving the grid.
    private func showEntryPopover(_ e: LibraryEntry, from: NSView) {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 420))
        tv.isEditable = false
        tv.textContainerInset = NSSize(width: 14, height: 14)
        tv.textStorage?.setAttributedString(popoverDoc(for: e))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 420))
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        let vc = NSViewController()
        vc.view = scroll
        entryPopover.contentViewController = vc
        entryPopover.contentSize = NSSize(width: 460, height: 420)
        entryPopover.behavior = .transient
        guard window?.isVisible == true else { return }   // an off-screen (test) window has nothing to anchor to
        entryPopover.show(relativeTo: from.bounds, of: from, preferredEdge: .maxX)
    }

    /// The "+N more" overflow chip drops to the list, filtered to that day — the full-detail path.
    private func dropToDayList(_ day: String) { dropToList(day: day, select: nil) }

    /// An audio chip has no transcript for a popover — drop to the list on its day and select it so the
    /// player bar appears (the list path already special-cases audio playback).
    private func openEntryInList(_ e: LibraryEntry) { dropToList(day: e.day, select: e) }

    private func dropToList(day: String, select: LibraryEntry?) {
        entryPopover.close()
        setMonthMode(false)
        selectedDay = day
        calendarView.syncSelection(day)
        updateModeVisibility()
        applyFilter()
        if let e = select, let fresh = shownDays.lazy.flatMap(\.entries).first(where: { $0.url == e.url && $0.kind == e.kind }) {
            showEntry(fresh)
            reselect(url: fresh.url, kind: fresh.kind)
        }
    }

    private var renderedStatusRows: [HealthRow]? // last rendered — skip the 1 Hz rebuild when nothing changed
    private func rebuildStatusPane() {
        let rows = todayHealth(healthSample?() ?? HealthInputs())
        // The tick fires every second, but the rows rarely change — rebuilding an unchanged pane made
        // it visibly twitch (user report: "화면이 움직인다"). Only rebuild on a real change.
        guard rows != renderedStatusRows else { return }
        renderedStatusRows = rows
        statusPane.arrangedSubviews.forEach { $0.removeFromSuperview() }
        statusActions = []
        var lastGroup = ""
        for row in rows {
            if row.group != lastGroup {
                lastGroup = row.group
                let g = NSTextField(labelWithString: row.group.uppercased())
                g.font = .systemFont(ofSize: 10, weight: .bold)
                g.textColor = .tertiaryLabelColor
                statusPane.addArrangedSubview(g)
            }
            let title = healthActionTitle(row.action)
            let v = makeHealthRowView(row, actionTitle: title,
                                      target: title == nil ? nil : self,
                                      action: title == nil ? nil : #selector(statusActionTapped(_:)),
                                      tag: statusActions.count)
            statusActions.append(row.action)
            statusPane.addArrangedSubview(v)
        }
    }

    @objc private func statusActionTapped(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < statusActions.count else { return }
        onHealthAction?(statusActions[sender.tag])
    }

    /// The overlay's rendered stream, mirrored into the main window's Live pane (same text).
    private var pendingLiveMirror: NSAttributedString?
    /// The live session ended — a later visit must not replay the dead session's captions.
    func liveMirrorClear() {
        pendingLiveMirror = nil
        liveText.textStorage?.setAttributedString(NSAttributedString(string: ""))
    }
    func liveMirror(_ text: NSAttributedString) {
        // The overlay renders many times a second — cache off-screen, paint only when the pane
        // shows (a caption arriving while browsing Library must still be there on entering Live).
        guard section == .live, window?.isVisible == true || fixtureDays != nil else {
            pendingLiveMirror = text
            return
        }
        liveText.textStorage?.setAttributedString(text)
        liveText.scrollToEndOfDocument(nil)
    }

    // Section test hooks: drive the real switch, read the observable pane state.
    func switchSectionForTest(_ s: MainSection) { switchSection(s) }
    var livePaneHiddenForTest: Bool { livePane.isHidden }
    var statusPaneHiddenForTest: Bool { statusPane.isHidden }
    var summaryBarHiddenForTest: Bool { summaryBar.isHidden }
    var statusTimerLiveForTest: Bool { statusTimer != nil }
    var statusRowCountForTest: Int { statusPane.arrangedSubviews.count }
    var liveMirrorTextForTest: String { liveText.string }

    @objc private func filterChanged() { applyFilter() }
    @objc private func refreshClicked() { refresh() }

    /// Expand the search field and focus it; a second click (or leaving it empty) collapses it back
    /// to the magnifier so the top row isn't a permanently-wide field over mostly-empty space.
    @objc private func toggleSearch() {
        if searchField.isHidden {
            searchField.isHidden = false
            searchToggle.isHidden = true   // the field carries its own magnifier — don't double it
            window?.makeFirstResponder(searchField)
        } else {
            collapseSearchIfEmpty(force: true)
        }
    }

    private func collapseSearchIfEmpty(force: Bool) {
        guard force || searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searchField.stringValue = ""
        searchField.isHidden = true
        searchToggle.isHidden = false   // restore the collapsed magnifier at the right end
        applyFilter()
        if window?.firstResponder === searchField.currentEditor() { window?.makeFirstResponder(nil) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        collapseSearchIfEmpty(force: false)   // left empty → tidy back to the icon
    }

    /// Static so the background closure can't race on window state; reuses an unchanged body by mtime.
    private static func buildIndex(_ entries: [LibraryEntry], from cached: [URL: IndexedBody]) -> [URL: IndexedBody] {
        let fm = FileManager.default
        let cap = 512 * 1024   // BYTES, not characters — Korean transcripts are ~3 B/char, so a Character
        func mtime(_ url: URL) -> Date? { (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }
        var index: [URL: IndexedBody] = [:]
        for e in entries {
            let sources = [e.url, e.summaryURL].compactMap { $0 }
            let sig = sources.map { mtime($0).map { "\($0.timeIntervalSince1970)" } ?? "-" }.joined(separator: "|")
            if let hit = cached[e.url], hit.sig == sig { index[e.url] = hit; continue } // unchanged → reuse
            var orig = ""
            for url in sources where fm.fileExists(atPath: url.path) {
                if let s = try? String(contentsOf: url, encoding: .utf8) { orig += (orig.isEmpty ? "" : "\n") + s }
            }
            // cap bounds resident memory (orig + its lowercased copy); decode tolerates a mid-char cut.
            let clipped = orig.utf8.count <= cap ? orig : String(decoding: Array(orig.utf8.prefix(cap)), as: UTF8.self)
            if !clipped.isEmpty { index[e.url] = IndexedBody(sig: sig, lower: clipped.lowercased(), orig: clipped) }
        }
        return index
    }

    private func publishIndex(_ index: [URL: IndexedBody]) {
        contentIndex = index
        contentLower = index.mapValues(\.lower)
    }

    /// Off the main thread: a big library would beach-ball the first keystroke. Re-run the filter (not a
    /// fresh kick — that loops) once the fuller index lands.
    private func refreshContentIndexAsync() {
        guard !contentIndexRefreshing else { return }
        contentIndexRefreshing = true
        let entries = allDays.flatMap(\.entries)
        let cached = contentIndex
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let index = Self.buildIndex(entries, from: cached)
            DispatchQueue.main.async {
                guard let self else { return }
                self.contentIndexRefreshing = false
                self.publishIndex(index)
                if !self.searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { self.applyFilterCore() }
            }
        }
    }

    /// Cached so heightOfRowByItem and viewFor don't each re-scan the body for the same row.
    private func rowSnippet(_ e: LibraryEntry) -> String? { rowSnippetCache[e.url] }

    /// Rebuild the row-snippet cache for the currently visible rows (once per applyFilterCore reload).
    private func rebuildRowSnippetCache() {
        rowSnippetCache = [:]
        let q = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        for e in shownDays.flatMap(\.entries) where !libraryMetadataMatches(e, filter: q) {
            if let body = contentIndex[e.url]?.orig, let snip = searchSnippet(body, term: q) { rowSnippetCache[e.url] = snip }
        }
    }

    private func applyFilter() {
        // Kick a background (incremental) index refresh when searching; the CORE filter runs immediately
        // with whatever content is cached, so the list stays responsive and body matches fill in after.
        if !searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { refreshContentIndexAsync() }
        applyFilterCore()
    }

    private func applyFilterCore() {
        let onlyKind: LibraryEntry.Kind? = scopePicker.selectedSegment == 1 ? .digest : nil
        shownDays = libraryFiltered(allDays, filter: searchField.stringValue, onlyKind: onlyKind,
                                    day: selectedDay, content: contentLower)
        rebuildRowSnippetCache()   // one scan feeds both heightOfRowByItem and viewFor for this reload
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        emptyLabel.isHidden = !shownDays.isEmpty || (monthMode && section == .library)   // never over the grid
        // The daily-specific copy only when the SCOPE, not an active text filter, emptied the list —
        // a digest has no searchable title, so any real query hides them and "no digests yet" would
        // lie (review finding).
        let filterActive = !searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        // The picked-day case reads FIRST and folds the scope in — with a day picked AND the Daily
        // scope, "no daily digests yet" would blame the wrong filter (review finding).
        emptyLabel.stringValue = allDays.isEmpty
            ? "Nothing here yet — transcripts appear as meetings are recorded."
            : (selectedDay != nil && !filterActive)
            ? "No \(onlyKind == .digest ? "daily digests" : "recordings") on \(selectedDay ?? "")"
            + " — click the date again, or ✕ under the calendar, to show every day."
            : (onlyKind == .digest && !filterActive) ? "No daily digests yet — they're written once a day."
            : "No match for the current filter."
        // Keep the preview in sync: the selected file may be gone after a rescan (showEntry(nil)
        // re-derives the header itself). The header/spinner is a function of the SELECTED entry, not
        // the filter text — so do NOT re-derive it here, or every filter keystroke re-animates the
        // re-run spinner (maintainer found it spinning during filtering). refresh() handles the
        // prefs-changed case below.
        if let sel = selected {
            // Match by STABLE IDENTITY (url + kind), not the whole value: a rescan that lands a summary
            // (or renames/attaches audio) changes the entry's metadata while the same row stays visible,
            // and a value-equality miss would wrongly clear the user's preview. Rebind to the fresh entry
            // so the picker/player pick up the new summary; clear only when the row is truly gone.
            if let fresh = shownDays.lazy.flatMap(\.entries).first(where: { $0.url == sel.url && $0.kind == sel.kind }) {
                if fresh != sel { showEntry(fresh) }
            } else {
                showEntry(nil) // the selected row was filtered out / deleted
            }
        } else if standaloneURL == nil {
            // Nothing selected: repaint the empty pane so its invite/blank tracks the VISIBLE list —
            // a day-pick or filter that empties the list must drop the "select on the left" invite (it
            // would contradict the "No recordings" notice), and the first open must gain it post-scan.
            showEntry(nil)
        }
    }

    /// The one decision for the right pane: which entry, and which of its documents. Everything —
    /// header text, picker visibility, player bar, button enablement, the text itself — derives
    /// from here, so a clickable control can never point at a document that isn't there.
    private func showEntry(_ entry: LibraryEntry?) {
        stopPlayback()   // switching rows silences the previous file and resets the bar
        standaloneURL = nil   // a real selection supersedes any tray-fallback standalone render
        selected = entry
        guard let e = entry else {
            headerLabel.stringValue = ""
            headerLabel.toolTip = nil
            docPicker.isHidden = true
            playerBar.isHidden = true
            // NOTHING is selected: hide the whole action strip — disabled-but-visible buttons over
            // an empty pane read as broken (user report: an empty day pick "breaks" the UI).
            headBar.isHidden = true
            summaryBar.isHidden = true
            openBtn.isEnabled = false
            revealBtn.isEnabled = false
            deleteBtn.isEnabled = false
            applyHeaderActions()
            // A blank right pane read as half-built (user report). Invite a pick only when the VISIBLE
            // list has rows to pick — a filter/day-pick that empties the list already shows its own
            // centered "No …" notice, and "select on the left" over an empty left pane would contradict it.
            setPlainDoc(shownDays.isEmpty ? "" : "\n\nSelect a recording on the left to read its transcript and summary.",
                        centered: true)
            return
        }
        headBar.isHidden = false
        summaryBar.isHidden = false
        let day = libraryDayLabel(day: e.day, today: Self.dayString(Date()),
                                  yesterday: Self.dayString(Date().addingTimeInterval(-86400)))
        // The sidebar already shows the day — the header spends its width on the title (the
        // "day · time" prefix squeezed real titles down to four characters next to the buttons).
        let spec = libraryRowSpec(e)
        headerLabel.stringValue = spec.text
        headerLabel.toolTip = "\(day) · \(spec.text)"
        docPicker.isHidden = e.summaryURL == nil
        // Summary first: the distilled note is what the user reaches for; the raw transcript is
        // the appendix. The picker defaults to Summary whenever one exists (segment 0 = Summary).
        if !docPicker.isHidden { docPicker.selectedSegment = 0 }
        // Discoverability: seek links live on the Transcript view only — say so where the switch is.
        docPicker.setToolTip(e.audioURL != nil ? "Timestamps here play the recording" : nil, forSegment: 1)
        playerBar.isHidden = e.audioURL == nil
        openBtn.isEnabled = true
        revealBtn.isEnabled = true
        deleteBtn.isEnabled = true
        applyHeaderActions()
        loadDoc()
    }

    /// The URL the right pane is currently showing (summary first — segment 0 — or the transcript).
    private func currentDocURL() -> URL? {
        guard let e = selected else { return standaloneURL }   // standalone fallback (tray: not indexed)
        if !docPicker.isHidden, docPicker.selectedSegment == 0, let s = e.summaryURL { return s }
        return e.url
    }

    private func loadDoc() {
        guard let e = selected, let url = currentDocURL() else { return }
        if e.kind == .audio {   // no document to read — the player bar is the content
            setPlainDoc("Audio-only recording (no transcript) — press ▶ to play, or Open it in your player.")
            return
        }
        // Cap the read so a runaway file can't beachball the window, then render the markdown —
        // links resolve relative to the document, so the transcript's audio link stays clickable.
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            let capped = data.prefix(2_000_000)
            let text = String(decoding: capped, as: UTF8.self)
                + (data.count > capped.count ? "\n\n… (truncated view — Open shows the full file)" : "")
            // Seek links only on the TRANSCRIPT view of a row that has audio: the line stamps and
            // the stem's start minute are both wall-clock, so their difference is the play offset.
            let showingTranscript = docPicker.isHidden || docPicker.selectedSegment == 1
            let start = (e.kind == .transcript && showingTranscript && e.audioURL != nil)
                ? libraryStartSeconds(e.time) : nil
            textView.textStorage?.setAttributedString(
                MarkdownRender.render(text, baseURL: url, transcriptStart: start))
        } else {
            setPlainDoc("(could not read \(url.path))")
        }
        textView.scrollToBeginningOfDocument(nil)
    }

    /// Plain messages go through the SAME attributed channel as rendered documents — assigning
    /// textView.string after setAttributedString inherits whatever font/paragraph style the last
    /// document ended with (a heading-first doc left the error message in 19 pt bold).
    private func setPlainDoc(_ msg: String, centered: Bool = false) {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        if centered {
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            attrs[.paragraphStyle] = p
        }
        textView.textStorage?.setAttributedString(NSAttributedString(string: msg, attributes: attrs))
    }

    // MARK: audio playback

    /// Lazily open the selected entry's audio. Failure is stated in the clock label — a play button
    /// that silently does nothing is exactly the dead-affordance bug this codebase keeps re-learning.
    private func loadPlayerIfNeeded() -> AVAudioPlayer? {
        if let p = player { return p }
        guard let u = selected?.audioURL else { return nil }
        do {
            let p = try AVAudioPlayer(contentsOf: u)
            p.delegate = self
            player = p
            seekSlider.maxValue = max(p.duration, 0.1)
            updatePlayerClock()
            return p
        } catch {
            // "missing" and "undecodable" need different user actions (rescan vs blame the codec).
            clockLabel.stringValue = FileManager.default.fileExists(atPath: u.path)
                ? "unplayable (\(u.pathExtension))" : "missing audio file — Refresh"
            elog("library: could not open audio \(u.lastPathComponent) — \(error)")
            return nil
        }
    }

    @objc private func togglePlay() {
        guard let p = loadPlayerIfNeeded() else { return }
        if p.isPlaying {
            p.pause()
            playBtn.title = "▶"
            playerTimer?.invalidate(); playerTimer = nil
        } else {
            p.play()
            playBtn.title = "⏸"
            startPlayerTimer()
        }
        updatePlayerClock()
    }

    @objc private func seekChanged() {
        // Before the lazy first load the slider runs 0…1 (placeholder), so a drag is a FRACTION;
        // mapping it straight to seconds would land every pre-play seek inside the first second.
        let hadPlayer = player != nil
        let fraction = seekSlider.doubleValue / max(seekSlider.maxValue, 0.0001)
        guard let p = loadPlayerIfNeeded() else { return }
        if !hadPlayer { seekSlider.doubleValue = fraction * p.duration }
        p.currentTime = min(seekSlider.doubleValue, max(p.duration - 0.05, 0))
        updatePlayerClock()
    }

    private func startPlayerTimer() {
        playerTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.updatePlayerClock() }
        RunLoop.main.add(t, forMode: .common)
        playerTimer = t
    }

    private func updatePlayerClock() {
        guard let p = player else {
            seekSlider.doubleValue = 0
            clockLabel.stringValue = "--:-- / --:--"
            return
        }
        if !seekSlider.cell!.isHighlighted { seekSlider.doubleValue = p.currentTime }   // don't fight a drag
        clockLabel.stringValue = "\(libraryClock(p.currentTime)) / \(libraryClock(p.duration))"
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        playerTimer?.invalidate(); playerTimer = nil
        playBtn.title = "▶"
        seekSlider.doubleValue = 0
        seekSlider.maxValue = 1
        clockLabel.stringValue = "--:-- / --:--"
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.playBtn.title = "▶"
            self.playerTimer?.invalidate(); self.playerTimer = nil
            self.updatePlayerClock()
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopPlayback()
        statusTimer?.invalidate(); statusTimer = nil   // a closed window must not keep a 1 Hz timer
    }

    // MARK: split view (classic sizing — see build())

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 240)   // the list never collapses
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - 300)   // the document keeps room
    }

    @objc private func rowSelected() {
        let item = outline.item(atRow: outline.selectedRow)
        if item is LibraryEntry, section != .library { switchSection(.library) }   // a recording click IS Library
        showEntry(item as? LibraryEntry)
    }

    @objc private func docPicked() { loadDoc() }
    @objc private func openDoc() { if let u = currentDocURL() { NSWorkspace.shared.open(u) } }
    @objc private func revealDoc() {
        if let u = currentDocURL() { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    /// The (role, file) pairs a delete would remove: EXISTING on disk, and NOT referenced by any OTHER
    /// indexed entry (so deleting one recording can never orphan a file a twin still points at — a
    /// stem-collision across folders). Role labels disambiguate the confirm sheet (a dedicated summary
    /// dir gives the summary the transcript's basename, so bare names would read identically).
    private func deletionFiles(_ e: LibraryEntry) -> [(role: String, url: URL)] {
        let othersUse = Set(allDays.flatMap(\.entries).filter { $0 != e }
            .flatMap { [$0.url, $0.summaryURL, $0.audioURL].compactMap { $0?.standardizedFileURL.path } })
        let fm = FileManager.default
        return libraryDeletionSet(e).compactMap { u in
            guard fm.fileExists(atPath: u.path), !othersUse.contains(u.standardizedFileURL.path) else { return nil }
            let role: String
            switch true {
            case u == e.url: role = e.kind == .digest ? "digest" : "transcript"
            case u == e.summaryURL: role = "summary"
            case ["wav", "m4a"].contains(u.pathExtension.lowercased()): role = "audio"
            case u.pathExtension.lowercased() == "json": role = "structured data"
            default: role = "file"
            }
            return (role, u)
        }
    }

    /// Delete the selected recording — confirm FIRST (destructive, user asked), then move its files to
    /// the Trash (recoverable, not a permanent rm). The sheet lists exactly what goes, by role, so
    /// nothing is removed unseen. A failure to trash any file is surfaced, not just logged.
    @objc private func deleteClicked() {
        if let e = selected { confirmDelete(e) }
    }

    /// The shared confirm→Trash flow, entry-parameterized so BOTH the detail-pane Delete and each list
    /// row's trash button (user ask: the affordance must live on the list too) run the same path.
    func confirmDelete(_ e: LibraryEntry) {
        // Click-through seam: with the hook set, a performClick on a row's
        // trash button records WHICH entry the real target/action chain resolved to — proving the
        // click path end-to-end without a modal sheet in a headless test.
        if let hook = confirmDeleteHookForTest { hook(e); return }
        guard let win = window else { return }
        let files = deletionFiles(e)
        guard !files.isEmpty else { refresh(); return }   // files already gone → drop the stale row, not a dead click
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this recording?"
        alert.informativeText = "These files move to the Trash (recover them there if needed):\n\n"
            + files.map { "• \($0.role): \($0.url.lastPathComponent)" }.joined(separator: "\n")
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self else { return }
            let failed = self.performDelete(e)
            guard !failed.isEmpty, let w = self.window else { return }
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Some files couldn't be moved to the Trash"
            a.informativeText = "Still on disk (try again, or move them in Finder):\n\n"
                + failed.map { "• \($0.lastPathComponent)" }.joined(separator: "\n")
            a.addButton(withTitle: "OK")
            a.beginSheetModal(for: w, completionHandler: nil)
        }
    }

    /// Move the recording's files to the Trash, then clear the pane + rescan so the row is gone. `remove`
    /// is injectable so the selftest drives the real loop without littering the Trash. Returns the files
    /// that COULD NOT be removed (empty on full success) — the caller surfaces a shortfall, never silent.
    @discardableResult
    func performDelete(_ e: LibraryEntry,
                       remove: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> [URL] {
        var failed: [URL] = []
        for (_, url) in deletionFiles(e) {
            do { try remove(url) }
            catch { elog("library: delete failed for \(url.lastPathComponent) — \(error.localizedDescription)"); failed.append(url) }
        }
        if selected == e { showEntry(nil) }   // the deleted row can no longer be shown
        refresh()                             // rescan → the entry is gone from the sidebar
        return failed
    }

    // MARK: seek links (a rendered "[HH:MM:SS]" stamp → the player)

    /// A transcript stamp was clicked: seek the lazily loaded player there and play. Foreign links
    /// return false → NSTextView's default handling (NSWorkspace) — macrec-seek: never reaches it.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        // A checkbox click flips the SOURCE line and re-renders — the file is the truth.
        if let n = macrecCheckLine(link) { toggleCheckbox(atSourceLine: n); return true }
        guard let secs = macrecSeekSeconds(link) else { return false }
        guard let p = loadPlayerIfNeeded() else { return true }   // failure is on the clock label
        p.currentTime = min(secs, max(p.duration - 0.05, 0))      // a stamp past EOF lands at the end
        if !p.isPlaying {
            p.play()
            playBtn.title = "⏸"
            startPlayerTimer()
        }
        updatePlayerClock()
        return true
    }

    // MARK: preview-header actions (Export… / Re-run summary)

    /// Materialize the ONE decision (librarySummarySlot + libraryExportEnabled) into the strip.
    /// Called whenever an input moves: selection, a rescan, a run starting/ending.
    private func applyHeaderActions() {
        let exportOn = libraryExportEnabled(selected?.kind)
        exportBtn.isEnabled = exportOn
        exportBtn.isHidden = !exportOn   // non-transcript rows have nothing to convert — no dead chrome
        let slot = currentSummarySlot()
        // Section gate: refresh()/windowDidBecomeKey call this regardless of section — outside
        // Library the bar must stay down or it bleeds over the Status/Live pane.
        summaryBar.isHidden = section != .library
            || (!exportOn && slot.buttonTitle == nil && !slot.spinning && slot.status == nil)
        rerunBtn.isHidden = slot.buttonTitle == nil
        if let t = slot.buttonTitle { rerunBtn.title = t }
        rerunSpinner.isHidden = !slot.spinning
        if slot.spinning { rerunSpinner.startAnimation(nil) } else { rerunSpinner.stopAnimation(nil) }
        rerunStatus.isHidden = slot.status == nil
        rerunStatus.stringValue = slot.status ?? ""
        rerunStatus.toolTip = slot.status   // the label truncates; the full reason lives here
    }

    private func currentSummarySlot() -> LibrarySummarySlot {
        guard let e = selected else {
            return librarySummarySlot(kind: nil, hasInvocation: false, writesSummaryFile: false,
                                      hasSummary: false, phase: .idle)
        }
        let mode = effectivePostProcessMode(
            rawMode: Pref.explicit(Pref.postProcessMode, "MR_POST_PROCESS_MODE"),
            shellCmd: Pref.postProcessCommand)
        let inv = e.kind == .transcript ? postProcessInvocationFromPrefs(transcriptPath: e.url.path) : nil
        return librarySummarySlot(kind: e.kind, hasInvocation: inv != nil,
                                  writesSummaryFile: postProcessWritesSummaryFile(mode),
                                  hasSummary: e.summaryURL != nil,
                                  phase: currentPhase(for: e))
    }

    /// This transcript's run state, from EVERY source that can know about one: the Library's own
    /// runs (rerunPhase), the engine's in-flight automatic run (the SummaryStatus registry — the
    /// button must never offer a second, racing run), and the engine's LAST failure (so an
    /// overnight "Summary failed" is visible here, not only as a long-dismissed notification).
    private func currentPhase(for e: LibraryEntry) -> LibraryRerunPhase {
        if SummaryStatus.shared.isRunning(path: e.url.path) { return .running }   // any runner, any surface
        if let p = rerunPhase[e.url] { return p }
        if case .failed(let file, _, let reason) = SummaryStatus.shared.current,
           file == e.url.lastPathComponent { return .failed(reason ?? "see the log") }
        return .idle
    }

    /// Test seam: selftests inject a stub so the wiring is driven without spawning a real agent CLI
    /// (a test that runs the machine's `claude` fails on someone else's machine). nil = the real runner.
    var runCommandForTest: ((String, @escaping (Int32) -> Void) -> Void)?

    @objc private func rerunClicked() {
        guard let e = selected, e.kind == .transcript, rerunPhase[e.url] != .running else { return }
        // Re-derive at click time: prefs may have changed since the header was drawn, and the
        // ENGINE may have started its own run for this file (registry) — a stale button re-hides
        // or re-derives the slot instead of dead-ending or racing onto the same .partial files.
        let mode = effectivePostProcessMode(
            rawMode: Pref.explicit(Pref.postProcessMode, "MR_POST_PROCESS_MODE"),
            shellCmd: Pref.postProcessCommand)
        guard !SummaryStatus.shared.isRunning(path: e.url.path),
              postProcessWritesSummaryFile(mode),
              let cmd = postProcessInvocationFromPrefs(transcriptPath: e.url.path) else {
            applyHeaderActions()
            return
        }
        let target = e.url
        let file = target.lastPathComponent
        let out = summaryOutputPath(transcriptPath: target.path,
                                    outDir: Pref.explicit(Pref.summaryOut, "MR_SUMMARY_OUT"))
        rerunPhase[target] = .running
        applyHeaderActions()
        SummaryStatus.shared.started(file)   // the tray row mirrors the run, like an automatic one
        SummaryStatus.shared.beginRun(path: target.path)
        let run = runCommandForTest ?? { c, done in runPostProcessCommand(c, completion: done) }
        run(cmd) { [weak self] status in
            DispatchQueue.main.async { self?.rerunFinished(target: target, file: file, out: out, status: status) }
        }
    }

    private func rerunFinished(target: URL, file: String, out: String, status: Int32) {
        SummaryStatus.shared.endRun(path: target.path)
        if status == 0 {
            rerunPhase[target] = nil
            SummaryStatus.shared.finished(file, at: Date(), output: out)
            // The fresh summary must show up: rescan, then re-select the same file — the selected
            // VALUE is stale (it just gained a summaryURL) and would otherwise clear the preview.
            let wasSelected = selected?.url == target
            refresh()
            if wasSelected { reselect(url: target, kind: .transcript) }
        } else {
            let why = reapFailedPostProcess(outPath: out) ?? "exit \(status)"
            rerunPhase[target] = .failed(why)
            SummaryStatus.shared.failed(file, at: Date(), reason: why)
            elog("library: re-run summary exited \(status) for \(file) — \(why)")
            applyHeaderActions()
        }
    }

    /// Find the (fresh) entry for a file after a rescan and keep the user's place on it. The kind
    /// disambiguates: a digest row can share a day with the transcript being summarized.
    private func reselect(url: URL, kind: LibraryEntry.Kind) {
        for row in 0..<outline.numberOfRows {
            if let e = outline.item(atRow: row) as? LibraryEntry, e.url == url, e.kind == kind {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                showEntry(e)
                return
            }
        }
    }

    @objc private func exportClicked() {
        guard let e = selected, libraryExportEnabled(e.kind), let win = window,
              exportPanel == nil else { return }   // one panel: a second click must not steal the popup
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.message = "Export the transcript — Markdown as saved, or converted."
        exportFormatPopup.removeAllItems()
        exportFormatPopup.addItems(withTitles: TranscriptExportFormat.allCases.map(\.label))
        exportFormatPopup.target = self
        exportFormatPopup.action = #selector(exportFormatChanged)
        exportFormatPopup.selectItem(at: lastExportFormat)   // the user's last pick, not a reset
        let acc = NSStackView(views: [NSTextField(labelWithString: "Format:"), exportFormatPopup])
        acc.orientation = .horizontal
        acc.spacing = 6
        acc.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        acc.translatesAutoresizingMaskIntoConstraints = true
        acc.frame = NSRect(origin: .zero, size: acc.fittingSize)
        panel.accessoryView = acc
        let fmt0 = TranscriptExportFormat.allCases[lastExportFormat]
        panel.nameFieldStringValue = e.url.deletingPathExtension().lastPathComponent + "." + fmt0.ext
        if let t = UTType(filenameExtension: fmt0.ext) { panel.allowedContentTypes = [t] }
        exportPanel = panel
        let start = libraryStartSeconds(e.time)
        panel.beginSheetModal(for: win) { [weak self] resp in
            guard let self else { return }
            self.exportPanel = nil
            guard resp == .OK, let dest = panel.url else { return }
            let fmt = TranscriptExportFormat.allCases[max(0, self.exportFormatPopup.indexOfSelectedItem)]
            self.lastExportFormat = max(0, self.exportFormatPopup.indexOfSelectedItem)
            // Read at SAVE time (the file can be retitled/rewritten while the sheet sits open),
            // decoding lossily like the preview does — a stray byte must not fail the export.
            guard let data = try? Data(contentsOf: e.url) else {
                self.presentExportError("Could not read \(e.url.lastPathComponent)")
                return
            }
            let md = String(decoding: data, as: UTF8.self)
            // An SRT/VTT of a file with no stamped lines would be an empty subtitle file — refuse
            // loudly instead of writing a reassuring nothing.
            if let issue = transcriptExportIssue(md, format: fmt) {
                self.presentExportError(issue)
                return
            }
            let content = transcriptExportContent(md, format: fmt, startSeconds: start)
            do { try content.write(to: dest, atomically: true, encoding: .utf8) }
            catch { self.presentExportError("Could not write \(dest.lastPathComponent) — \(error.localizedDescription)") }
        }
    }

    /// Keep the proposed file name's extension in step with the chosen format.
    @objc private func exportFormatChanged() {
        guard let panel = exportPanel else { return }
        let fmt = TranscriptExportFormat.allCases[max(0, exportFormatPopup.indexOfSelectedItem)]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        if let t = UTType(filenameExtension: fmt.ext) { panel.allowedContentTypes = [t] }
        panel.nameFieldStringValue = base + "." + fmt.ext
    }

    private func presentExportError(_ msg: String) {
        elog("library: export failed — \(msg)")
        guard let win = window else { return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Export failed"
        a.informativeText = msg
        a.beginSheetModal(for: win)
    }

    private static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    // MARK: outline plumbing

    func outlineView(_ v: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return shownDays.count }
        return (item as? LibraryDay)?.entries.count ?? 0
    }

    func outlineView(_ v: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        // A row with a content snippet gets a second line; everyone else keeps the medium single-line height.
        if let e = item as? LibraryEntry, rowSnippet(e) != nil { return 40 }
        return 24
    }

    func outlineView(_ v: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return shownDays[index] }
        guard let day = item as? LibraryDay else { return shownDays[index] }
        return day.entries[index]
    }

    func outlineView(_ v: NSOutlineView, isItemExpandable item: Any) -> Bool { item is LibraryDay }
    func outlineView(_ v: NSOutlineView, isGroupItem item: Any) -> Bool { item is LibraryDay }
    func outlineView(_ v: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is LibraryEntry }

    /// An entry row's cell: icon + one-line label + an always-visible trash button (user ask: the
    /// delete affordance must be reachable from the LIST, not only the detail pane). The button is
    /// subtle (borderless, template-tinted) so a hundred rows don't shout; `entry`/`owner` are
    /// re-bound to the row's CURRENT entry on every reuse so a recycled cell can never delete a
    /// stale one.
    final class LibraryEntryCell: NSTableCellView {
        let deleteBtn: NSButton = {
            let b = NSButton()
            b.translatesAutoresizingMaskIntoConstraints = false
            b.bezelStyle = .inline
            b.isBordered = false
            // A TEMPLATE image (not palette-baked): the glyph then inverts with the emphasized blue
            // selection like the rest of the row, instead of staying dim gray on it.
            let img = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
            img?.isTemplate = true
            b.image = img
            b.contentTintColor = .secondaryLabelColor
            b.toolTip = "Move this recording's files to the Trash (asks first)"
            return b
        }()

        // A readable binding (not a closure) so the selftest can PROVE a recycled cell points at its
        // current row's entry — closure captures can't be inspected, and a stale capture is exactly
        // the reuse bug the guard exists for.
        var entry: LibraryEntry?
        weak var owner: LibraryWindow?

        override init(frame: NSRect) {
            super.init(frame: frame)
            deleteBtn.target = self
            deleteBtn.action = #selector(deleteTapped)
        }

        @available(*, unavailable) required init?(coder _: NSCoder) { nil }

        @objc private func deleteTapped() {
            if let e = entry { owner?.confirmDelete(e) }
        }
    }

    // A quiet gray selection instead of the emphasized accent-blue row (mono rule): AppKit renders
    // the unemphasized style when the row view opts out of emphasis.
    func outlineView(_ v: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let r = MonoRowView()
        r.isEmphasized = false
        return r
    }

    final class MonoRowView: NSTableRowView {
        override var isEmphasized: Bool { get { false } set {} }   // AppKit re-sets it on focus; pin it
    }

    func outlineView(_ v: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        // Day-group headers get their OWN cell with the label flush-left — the shared entry cell
        // reserves a 16 pt icon + 6 pt gap, which pushed the date right (maintainer found it).
        if let day = item as? LibraryDay {
            let gid = NSUserInterfaceItemIdentifier("group")
            let cell = v.makeView(withIdentifier: gid, owner: nil) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = gid
                let t = NSTextField(labelWithString: "")
                t.translatesAutoresizingMaskIntoConstraints = false
                t.lineBreakMode = .byTruncatingTail
                c.addSubview(t)
                c.textField = t
                NSLayoutConstraint.activate([
                    t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                    t.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = libraryDayLabel(
                day: day.day, today: Self.dayString(Date()),
                yesterday: Self.dayString(Date().addingTimeInterval(-86400)))
            cell.textField?.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = v.makeView(withIdentifier: id, owner: nil) as? LibraryEntryCell ?? {
            let c = LibraryEntryCell()
            c.identifier = id
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.contentTintColor = .secondaryLabelColor
            let t = NSTextField(labelWithString: "")
            t.translatesAutoresizingMaskIntoConstraints = false
            t.lineBreakMode = .byTruncatingTail
            t.maximumNumberOfLines = 1   // rows are one line, whatever the attributed text says
            t.cell?.truncatesLastVisibleLine = true
            c.addSubview(icon)
            c.addSubview(t)
            c.addSubview(c.deleteBtn)
            c.imageView = icon
            c.textField = t
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                t.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                t.trailingAnchor.constraint(equalTo: c.deleteBtn.leadingAnchor, constant: -4),
                t.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                c.deleteBtn.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                c.deleteBtn.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                c.deleteBtn.widthAnchor.constraint(equalToConstant: 18),
            ])
            return c
        }()
        if let day = item as? LibraryDay {
            cell.imageView?.image = nil
            cell.textField?.stringValue = libraryDayLabel(
                day: day.day, today: Self.dayString(Date()),
                yesterday: Self.dayString(Date().addingTimeInterval(-86400)))
            cell.textField?.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            cell.textField?.textColor = .secondaryLabelColor
        } else if let e = item as? LibraryEntry {
            let spec = libraryRowSpec(e)
            cell.imageView?.image = NSImage(systemSymbolName: spec.icon, accessibilityDescription: e.kind.rawValue)
            // Tinted, non-blue: a strong label for transcripts, orange/purple for digest/audio, so the
            // kind reads at a glance without washing out (a flat secondary gray looked pale — user report).
            cell.imageView?.contentTintColor = libraryTintColor(spec.tint)
            let font = NSFont.systemFont(ofSize: 12)
            // Attributed text carries its OWN paragraph style — without an explicit truncating
            // one it WRAPS, and a long real title overlapped the next row (fixture titles were
            // all short, so only real data showed it).
            let oneLine = NSMutableParagraphStyle()
            oneLine.lineBreakMode = .byTruncatingTail
            let text = NSMutableAttributedString(string: spec.text, attributes: [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: oneLine,
            ])
            // Trailing status icons ride inline as attachments, tinted like secondary text.
            for symbol in spec.trailing {
                let img = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .regular)
                        .applying(.init(paletteColors: [.secondaryLabelColor])))
                guard let img = img else { continue }
                let att = NSTextAttachment()
                att.image = img
                att.bounds = NSRect(x: 0, y: -1, width: img.size.width, height: img.size.height)
                text.append(NSAttributedString(string: "  "))
                text.append(NSAttributedString(attachment: att))
            }
            // Full-text hit: show WHY this row matched on a SECOND line — a dim snippet of the matching
            // line (only for a body-only hit; a title hit is self-evident). The row grows to fit it
            // (heightOfRowByItem), so the snippet is never squeezed off the end of the title.
            let snip = rowSnippet(e)
            if let snip {
                text.append(NSAttributedString(string: "\n" + snip, attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: oneLine,
                ]))
            }
            cell.textField?.maximumNumberOfLines = snip == nil ? 1 : 2
            cell.textField?.attributedStringValue = text
            // Re-bind on EVERY reuse: a recycled cell must delete ITS current entry, never the one it
            // showed before scrolling. The confirm→Trash flow is the same one the detail Delete runs.
            cell.entry = e
            cell.owner = self
            // VoiceOver must be able to tell WHICH recording each row's trash deletes.
            cell.deleteBtn.setAccessibilityLabel("Delete \(spec.text)")
        }
        return cell
    }

    // MARK: test kit (mirrors the Settings pane harness)

    /// Drop the shared window so the next loadFixtureForTest builds a FRESH one — lets a test observe
    /// build()'s own initial paint (e.g. the default nav selection) rather than a state left by an
    /// earlier test on the singleton.
    func resetWindowForTest() {
        statusTimer?.invalidate(); statusTimer = nil
        window?.close()
        window = nil
        navButtons = []   // makeWindow APPENDS; without this the rebuilt window keeps stale (painted) buttons
        renderedStatusRows = nil
    }

    /// Inject fixture data and build the window without touching the user's folders.
    func loadFixtureForTest(_ days: [LibraryDay]) {
        fixtureDays = days
        if window == nil { build() }
        refresh()
        // Select the richest fixture row (summary + audio) so the picker AND the player bar are
        // laid out — the layout guard and the snapshot must see every control that can exist.
        let all = shownDays.flatMap(\.entries)
        if let rich = all.first(where: { $0.summaryURL != nil && $0.audioURL != nil }) ?? all.first {
            showEntry(rich)
        }
    }

    /// Snapshot harness hook: open the audio player so the bar shows a real duration in the PNG.
    func primePlayerForTest() { _ = loadPlayerIfNeeded() }

    /// Snapshot/selftest hook: drive the scope segment (0 = All, 1 = Daily) like a click.
    func setScopeForTest(_ segment: Int) { scopePicker.selectedSegment = segment; applyFilter() }
    var shownDayCountForTest: Int { shownDays.count }

    /// Swap the fixture WITHOUT rebuilding or reselecting — lets a test change what the next
    /// refresh() "rescans" (e.g. a summary appearing mid-run), like the real disk would.
    func setFixtureForTest(_ days: [LibraryDay]) { fixtureDays = days }

    private(set) var checkboxFailureForTest: String?
    /// Flip the task box on `line` of the shown document and reload; drifted lines are refused.
    func toggleCheckbox(atSourceLine line: Int) {
        checkboxFailureForTest = nil
        guard let url = currentDocURL(),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            surfaceCheckboxFailure("The file could not be read — it may have moved.")
            return
        }
        guard let flipped = toggledCheckboxText(text, line: line) else {
            surfaceCheckboxFailure("The file changed since it was shown — refresh and try again.")
            elog("library: checkbox toggle refused — line \(line) drifted in \(url.lastPathComponent)")
            return
        }
        do {
            try flipped.write(to: url, atomically: true, encoding: .utf8)
            // Re-render via the path that produced the view (loadDoc blanks a standalone render).
            if standaloneURL != nil { renderStandalone(url) } else { loadDoc() }
        } catch {
            surfaceCheckboxFailure("Saving failed: \(error.localizedDescription)")
            elog("library: checkbox toggle failed for \(url.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    /// A failed click must be VISIBLE (silent-failure rule), not only logged.
    private func surfaceCheckboxFailure(_ msg: String) {
        checkboxFailureForTest = msg
        guard let win = window, win.isVisible else { return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Couldn't toggle the checkbox"
        a.informativeText = msg
        a.beginSheetModal(for: win, completionHandler: nil)
    }

    // Selection-driven state, readable by selftests: drive rows like a user, assert the derivation
    // (player bar visibility, lazy load, resets) without audible playback.
    func selectForTest(_ e: LibraryEntry?) { showEntry(e) }
    func refreshForTest() { refresh() }   // exercises the real refresh path (empty-pane hint repaint)
    /// Type into the REAL search field and fire its wired target-action (filterChanged) — so the test
    /// breaks if the field's action wiring breaks, not just if applyFilter changes.
    func setSearchForTest(_ s: String) {
        searchField.stringValue = s
        _ = searchField.target?.perform(searchField.action, with: searchField)
    }
    /// Click the REAL nav button (target-action → navTapped → switchSection), not switchSection direct.
    func clickNavForTest(_ s: MainSection) { navButtons.first { $0.tag == s.rawValue }?.performClick(nil) }
    /// Flip the REAL view-mode segmented control (List ⇄ Month) and fire its WIRED target-action — so a
    /// broken viewModePicker target/action fails the test, not just a helper call.
    func setMonthModeForTest(_ on: Bool) {
        viewModePicker.selectedSegment = on ? 1 : 0
        _ = viewModePicker.target?.perform(viewModePicker.action, with: viewModePicker)
    }
    func popoverDocForTest(_ e: LibraryEntry) -> NSAttributedString { popoverDoc(for: e) }
    var monthModeVisibleForTest: Bool { !monthView.isHidden }
    var splitVisibleForTest: Bool { !libSplit.isHidden }
    var monthChipCountForTest: Int { monthView.chipCountForTest() }
    @discardableResult func clickMonthChipForTest(onDay day: String) -> LibraryEntry? { monthView.clickFirstChipForTest(onDay: day) }
    /// Expand the search field (as the toggle does) and run a query, building the index SYNCHRONOUSLY so
    /// the assertion is deterministic (the shipped path builds it off-thread). Drives the real full-text path.
    func expandSearchForTest(_ term: String) {
        if searchField.isHidden { toggleSearch() }
        searchField.stringValue = term
        publishIndex(Self.buildIndex(allDays.flatMap(\.entries), from: contentIndex))
        applyFilterCore()
    }
    var rowSnippetForTest: (LibraryEntry) -> String? { { [weak self] in self?.rowSnippet($0) } }
    func collapseSearchForTest() { collapseSearchIfEmpty(force: true) }
    var searchFieldVisibleForTest: Bool { !searchField.isHidden }
    var searchToggleVisibleForTest: Bool { !searchToggle.isHidden }
    /// The active nav row must LOOK selected (fill + bold) and inactive rows must not — the fix for the
    /// "dead"/무반응 nav. Force the framework's layout first so the values read are the shipped ones.
    var navHighlightForTest: (activeFilled: Bool, activeBold: Bool, othersClear: Bool) {
        window?.contentView?.layoutSubtreeIfNeeded()
        let active = navButtons.first { $0.tag == section.rawValue }
        let activeW = active?.font.map { NSFontManager.shared.weight(of: $0) } ?? 0
        let inactiveW = navButtons.first { $0.tag != section.rawValue }?.font
            .map { NSFontManager.shared.weight(of: $0) } ?? 99
        let others = navButtons.filter { $0.tag != section.rawValue }
            .allSatisfy { $0.layer?.backgroundColor == nil }
        return (active?.layer?.backgroundColor != nil, activeW > inactiveW, others)
    }
    /// Drives the REAL show(selecting:) logic (selectIndexed + the standalone fallback) minus only the
    /// window-front hop, and returns the URL the right pane lands on — so the selftest exercises the
    /// actual method, not a mirror (test-honesty). nil when the target is neither indexed nor on disk.
    func showSelectingForTest(_ target: URL) -> URL? {
        refresh()
        if !selectIndexed(target) {
            guard FileManager.default.fileExists(atPath: target.path) else { return nil }
            renderStandalone(target)
        }
        return currentDocURL()
    }
    /// Row-delete wiring guard: every laid-out ENTRY row must carry a visible trash button that is
    /// wired (target+action) and bound to that row's OWN entry — a recycled cell still bound to a
    /// stale entry would trash the WRONG recording, the worst possible outcome for a delete control.
    func rowDeleteBindingsForTest() -> (rows: Int, bound: Int) {
        outline.layoutSubtreeIfNeeded()
        var rows = 0, bound = 0
        for r in 0..<outline.numberOfRows {
            guard let e = outline.item(atRow: r) as? LibraryEntry else { continue }
            rows += 1
            guard let cell = outline.view(atColumn: 0, row: r, makeIfNecessary: true) as? LibraryEntryCell,
                  cell.entry == e, cell.owner === self, !cell.deleteBtn.isHidden,
                  cell.deleteBtn.action != nil, cell.deleteBtn.target === cell else { continue }
            bound += 1
        }
        return (rows, bound)
    }

    /// Captures the entry a confirmDelete CLICK resolved to instead of showing the modal sheet —
    /// nil in production (the sheet shows). Set by the selftest around a performClick.
    var confirmDeleteHookForTest: ((LibraryEntry) -> Void)?

    /// The outline's item at `row` — lets the selftest find a named fixture row to click.
    func outlineItemForTest(row: Int) -> Any? {
        row < outline.numberOfRows ? outline.item(atRow: row) : nil
    }

    /// Fire a real performClick on the trash button of outline row `row` (an entry row) — drives
    /// the actual target/action chain, not a mirror of it. Returns false when the row has no cell.
    func clickRowDeleteForTest(row: Int) -> Bool {
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? LibraryEntryCell
        else { return false }
        cell.deleteBtn.performClick(nil)
        return true
    }

    // Calendar wiring hooks: drive a day pick through the REAL view + onPick chain, read the state.
    @discardableResult
    func calendarPickForTest(_ day: String) -> Bool { calendarView.pickForTest(day) }
    func calendarClickClearForTest() -> Bool { calendarView.clickClearForTest() }
    var selectedDayForTest: String? { selectedDay }
    var selectedURLForTest: URL? { selected?.url }   // the row the right pane is bound to
    var docPickerHiddenForTest: Bool { docPicker.isHidden }   // hidden ⇔ the selected row has no summary
    var calendarSelectedDayForTest: String? { calendarView.selectedDay }   // the VIEW's copy (desync guard)
    var calendarMonthForTest: String { calendarView.month }
    func calendarDayButtonCountForTest() -> Int { calendarView.dayButtonCountForTest() }
    func calendarWeekRowCountForTest() -> Int { calendarView.weekRowCountForTest }
    func calendarFlipForTest(by: Int) { calendarView.flipForTest(by: by) }

    var headBarHiddenForTest: Bool { headBar.isHidden }
    var playerBarHiddenForTest: Bool { playerBar.isHidden }
    var playerActiveForTest: Bool { player != nil }
    var openEnabledForTest: Bool { openBtn.isEnabled }
    var deleteEnabledForTest: Bool { deleteBtn.isEnabled }   // #37: pinned — Delete's gating differs from Open/Reveal
    var docTextForTest: String { textView.string }
    var clockTextForTest: String { clockLabel.stringValue }
    var seekMaxForTest: Double { seekSlider.maxValue }
    // Increment-2 hooks: header actions + seek links, driven like a user but without panels/audio.
    var exportEnabledForTest: Bool { exportBtn.isEnabled }
    var rerunButtonTitleForTest: String? { rerunBtn.isHidden ? nil : rerunBtn.title }
    var rerunSpinningForTest: Bool { !rerunSpinner.isHidden }
    var rerunStatusForTest: String? { rerunStatus.isHidden ? nil : rerunStatus.stringValue }

    /// Alignment guard (the day-header-shifted-right bug): how far the DAY-header text is inset from
    /// its OWN cell's leading edge. The bug shared the entry cell, whose text sits after a 16pt icon
    /// + 6pt gap (~22pt inset); the fix's group cell puts the text at ~2pt. The outline's own
    /// child-indentation is factored OUT by measuring within the cell, so this catches the real
    /// defect (which comparing day-vs-entry x did not — the outline indents children regardless).
    /// nil if no day row is laid out.
    func dayHeaderTextInsetForTest() -> CGFloat? {
        outline.reloadData(); outline.expandItem(nil, expandChildren: true)
        outline.layoutSubtreeIfNeeded()
        for r in 0 ..< outline.numberOfRows where outline.item(atRow: r) is LibraryDay {
            guard let cell = outline.view(atColumn: 0, row: r, makeIfNecessary: true) as? NSTableCellView,
                  let t = cell.textField else { continue }
            return t.convert(t.bounds, to: cell).minX
        }
        return nil
    }
    var playerTimeForTest: Double { player?.currentTime ?? -1 }
    var playerPlayingForTest: Bool { player?.isPlaying ?? false }
    var docAttributedForTest: NSAttributedString { textView.attributedString() }
    func rerunClickForTest() { rerunClicked() }
    func resetRerunForTest() { rerunPhase.removeAll() }
    func mutePlayerForTest() { player?.volume = 0 }
    func clickLinkForTest(_ link: Any) -> Bool { textView(textView, clickedOnLink: link, at: 0) }
    func pickDocForTest(_ segment: Int) {
        guard !docPicker.isHidden else { return }
        docPicker.selectedSegment = segment
        loadDoc()
    }

    /// AUTOMATED LAYOUT GUARD (selftest): any control collapsed to ~zero or overlapping another.
    func layoutIssues() -> [String] {
        guard let win = window, let content = win.contentView else { return ["library: no window"] }
        win.setContentSize(NSSize(width: 860, height: 540))
        content.layoutSubtreeIfNeeded()
        var issues: [String] = []
        var rects: [(String, NSRect)] = []
        // A scroll view's DOCUMENT view extends past its clip — convert() knows coordinates, not
        // clipping — so compare only the VISIBLE part, or the two document panes "overlap" headlessly.
        func visibleRect(_ v: NSView) -> NSRect {
            var f = v.convert(v.bounds, to: content)
            var a = v.superview
            while let anc = a, anc !== content {
                if anc is NSClipView { f = f.intersection(anc.convert(anc.bounds, to: content)) }
                a = anc.superview
            }
            return f
        }
        func walk(_ v: NSView) {
            if v.isHidden { return }
            if v is NSScroller { return }
            // NSProgressIndicator is an NSView, NOT an NSControl — without the explicit clause the
            // spinner would be invisible to this guard (review finding: a crushed spinner, green suite).
            if v is NSControl || v is NSTextView || v is NSProgressIndicator {
                let name = "\(type(of: v))(\((v as? NSButton)?.title ?? (v as? NSTextField)?.stringValue ?? ""))"
                // Collapse is judged on the RAW frame, before clipping: a control crushed to ~zero
                // also has an empty visible rect, and the old visible-only check skipped it as
                // "scrolled out of view" (the header label shipped crushed to 0 width, guard green).
                let raw = v.convert(v.bounds, to: content)
                // A control that SHOWS text needs readable width — the crushed header label
                // measured 5 pt (bezel padding only) and sailed under a flat 4 pt bar.
                let hasText = ((v as? NSTextField)?.stringValue.isEmpty == false)
                    || ((v as? NSButton)?.title.isEmpty == false)
                let minSide: CGFloat = hasText ? 12 : 4
                if raw.width < minSide || raw.height < minSide {
                    issues.append("library: \(name) collapsed to \(raw)")
                    return
                }
                let f = visibleRect(v)
                if f.isEmpty { return }   // scrolled out of view — nothing to assert about overlap
                for (on, of) in rects where of.intersects(f) && of.intersection(f).width > 8
                    && of.intersection(f).height > 8 {
                    issues.append("library: \(name) overlaps \(on)")
                }
                rects.append((name, f))
                return // controls' own subviews (cell views) overlap by design
            }
            for s in v.subviews { walk(s) }
        }
        walk(content)
        return issues
    }

    /// UI TEST KIT (see `macrec library-snapshot`): render the fixture-filled window to a PNG.
    /// Taller than the layout guard's 860×540 on purpose: the fixture document's transcript section
    /// (the seek-link stamps) sits at the bottom, and the eyeball check must actually see it.
    func snapshot(to dir: URL) -> [URL] {
        guard let win = window, let content = win.contentView else { return [] }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        win.setContentSize(NSSize(width: 860, height: 960))
        content.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        let bounds = content.bounds
        guard bounds.width > 1, bounds.height > 1 else { return [] }
        let img = NSImage(size: bounds.size)
        img.lockFocus()
        win.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: bounds.size).fill()
            if let ctx = NSGraphicsContext.current {
                content.displayIgnoringOpacity(bounds, in: ctx)
            }
        }
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              !snapshotIsBlank(rep),
              let png = rep.representation(using: .png, properties: [:]) else { return [] }
        let url = dir.appendingPathComponent("library.png")
        try? png.write(to: url)
        return [url]
    }
}
