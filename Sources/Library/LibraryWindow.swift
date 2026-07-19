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
    enum Tint: String { case orange, blue, purple } // semantic — the cell maps to NSColors
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
    return LibraryRowSpec(icon: "text.bubble", tint: .blue, text: text, trailing: trailing)
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
    let s = summaryOut.isEmpty ? transcripts : summaryOut
    let d = dailyOut.isEmpty ? s : dailyOut
    return (transcripts, s, d, audioDir)
}

// MARK: - the Library window (the desktop app's first surface)

/// What got transcribed and summarized, by day — the tray menu shows only the LAST result, and
/// answering "what did macrec catch today?" used to mean digging through Finder. Left: days and
/// entries; right: the selected transcript/summary, with Open / Reveal for the real file.
final class LibraryWindow: NSObject, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSSplitViewDelegate, AVAudioPlayerDelegate, NSTextViewDelegate {
    static let shared = LibraryWindow()
    private var window: NSWindow?
    private let outline = NSOutlineView()
    private let searchField = NSSearchField()
    private let scopePicker = NSSegmentedControl()   // All | Daily (digests only)
    private let textView = NSTextView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let docPicker = NSSegmentedControl(labels: ["Summary", "Transcript"],
                                               trackingMode: .selectOne, target: nil, action: nil)
    private let openBtn = NSButton(title: "Open", target: nil, action: nil)
    private let revealBtn = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    private let exportBtn = NSButton(title: "Export Transcript…", target: nil, action: nil)
    // Transcript-actions row (its own row — squeezed into the header strip they crushed the title):
    // Export + the re-run slot (button OR spinner+label), derived in applyHeaderActions (one decision).
    private var summaryBar: NSStackView!
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
    private var shownDays: [LibraryDay] = []
    private var fixtureDays: [LibraryDay]? // test/snapshot data — nil means scan the real folders
    private var selected: LibraryEntry?

    func show() {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    /// Re-scan sources. Called on open, on focus, and when the engine saves a transcript — the
    /// index is a snapshot, and these are the events that invalidate it.
    func refresh() {
        allDays = fixtureDays ?? scanReal()
        // Prune re-run state for files the scan no longer sees (deleted/renamed) — in-flight runs
        // keep their entry so a completion can still land its failure reason.
        let urls = Set(allDays.flatMap(\.entries).map(\.url))
        rerunPhase = rerunPhase.filter { $0.value == .running || urls.contains($0.key) }
        applyFilter()
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
        return scanLibrary(transcriptsDir: URL(fileURLWithPath: roots.transcripts),
                           summaryDir: URL(fileURLWithPath: roots.summaries),
                           dailyDir: URL(fileURLWithPath: roots.daily),
                           audioDir: roots.audio.isEmpty ? nil : URL(fileURLWithPath: roots.audio))
    }

    // MARK: build

    private func build() {
        let w = EditKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        w.title = "macrec library"
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.minSize = NSSize(width: 640, height: 360)
        // The 1160×720 default is a suggestion — the user's own size/position wins across opens.
        w.setFrameAutosaveName("libraryWindow")
        let content = NSView()

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter by title or date"
        searchField.sendsSearchStringImmediately = true
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
        let bar = NSStackView(views: [searchField, scopePicker, refreshBtn])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 6, right: 10)
        bar.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

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

        // Right: header (what's selected + actions) over the document text.
        headerLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        headerLabel.lineBreakMode = .byTruncatingTail
        docPicker.target = self
        docPicker.action = #selector(docPicked)
        openBtn.target = self
        openBtn.action = #selector(openDoc)
        revealBtn.target = self
        revealBtn.action = #selector(revealDoc)
        exportBtn.target = self
        exportBtn.action = #selector(exportClicked)
        exportBtn.toolTip = "Save the transcript as Markdown, plain text, SRT or VTT"
        rerunBtn.target = self
        rerunBtn.action = #selector(rerunClicked)
        for b in [openBtn, revealBtn, exportBtn, rerunBtn] { b.bezelStyle = .rounded }
        rerunSpinner.style = .spinning
        rerunSpinner.controlSize = .small
        rerunSpinner.isDisplayedWhenStopped = false
        rerunStatus.font = NSFont.systemFont(ofSize: 11)
        rerunStatus.textColor = .secondaryLabelColor
        rerunStatus.lineBreakMode = .byTruncatingTail
        rerunStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let head = NSStackView(views: [headerLabel, NSView(), docPicker, openBtn, revealBtn])
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

        let right = NSStackView(views: [head, summaryBar, playerBar, rightScroll])
        right.orientation = .vertical
        right.spacing = 0
        right.distribution = .fill
        head.setContentHuggingPriority(.required, for: .vertical)
        summaryBar.setContentHuggingPriority(.required, for: .vertical)
        playerBar.setContentHuggingPriority(.required, for: .vertical)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(leftScroll)
        split.addArrangedSubview(right)
        // Classic (autoresizing) pane sizing, NOT autolayout: with anchored arranged subviews the
        // split view logged an ambiguous-layout warning and refused full divider dragging (observed
        // live the first night). Pane minimums live in the delegate instead.
        right.translatesAutoresizingMaskIntoConstraints = true
        right.autoresizingMask = [.width, .height]
        split.delegate = self
        split.autosaveName = "libraryDivider"

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true

        content.addSubview(bar)
        content.addSubview(split)
        content.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: bar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        w.contentView = content
        content.layoutSubtreeIfNeeded()
        split.setPosition(300, ofDividerAt: 0)   // list ≈ a third, document gets the rest
        window = w
        showEntry(nil)   // the right pane starts EMPTY — no ghost picker/player before a selection
    }

    // MARK: data → view

    @objc private func filterChanged() { applyFilter() }
    @objc private func refreshClicked() { refresh() }

    private func applyFilter() {
        let onlyKind: LibraryEntry.Kind? = scopePicker.selectedSegment == 1 ? .digest : nil
        shownDays = libraryFiltered(allDays, filter: searchField.stringValue, onlyKind: onlyKind)
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        emptyLabel.isHidden = !shownDays.isEmpty
        // The daily-specific copy only when the SCOPE, not an active text filter, emptied the list —
        // a digest has no searchable title, so any real query hides them and "no digests yet" would
        // lie (review finding).
        let filterActive = !searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        emptyLabel.stringValue = allDays.isEmpty
            ? "Nothing here yet — transcripts appear as meetings are recorded."
            : (onlyKind == .digest && !filterActive) ? "No daily digests yet — they're written once a day."
            : "No match for the current filter."
        // Keep the preview in sync: the selected file may be gone after a rescan.
        if let sel = selected,
           !shownDays.contains(where: { $0.entries.contains(sel) }) { showEntry(nil) }
        // Prefs may have changed since the header was drawn (Settings saved, then the window
        // refocused → refresh) — re-derive the action strip on every rescan.
        applyHeaderActions()
    }

    /// The one decision for the right pane: which entry, and which of its documents. Everything —
    /// header text, picker visibility, player bar, button enablement, the text itself — derives
    /// from here, so a clickable control can never point at a document that isn't there.
    private func showEntry(_ entry: LibraryEntry?) {
        stopPlayback()   // switching rows silences the previous file and resets the bar
        selected = entry
        guard let e = entry else {
            headerLabel.stringValue = ""
            headerLabel.toolTip = nil
            docPicker.isHidden = true
            playerBar.isHidden = true
            openBtn.isEnabled = false
            revealBtn.isEnabled = false
            applyHeaderActions()
            setPlainDoc("")
            return
        }
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
        applyHeaderActions()
        loadDoc()
    }

    /// The URL the right pane is currently showing (summary first — segment 0 — or the transcript).
    private func currentDocURL() -> URL? {
        guard let e = selected else { return nil }
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
    private func setPlainDoc(_ msg: String) {
        textView.textStorage?.setAttributedString(NSAttributedString(string: msg, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
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

    func windowWillClose(_ notification: Notification) { stopPlayback() }

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
        showEntry(item as? LibraryEntry)
    }

    @objc private func docPicked() { loadDoc() }
    @objc private func openDoc() { if let u = currentDocURL() { NSWorkspace.shared.open(u) } }
    @objc private func revealDoc() {
        if let u = currentDocURL() { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    // MARK: seek links (a rendered "[HH:MM:SS]" stamp → the player)

    /// A transcript stamp was clicked: seek the lazily loaded player there and play. Foreign links
    /// return false → NSTextView's default handling (NSWorkspace) — macrec-seek: never reaches it.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
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
        summaryBar.isHidden = !exportOn && slot.buttonTitle == nil && !slot.spinning && slot.status == nil
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

    func outlineView(_ v: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return shownDays[index] }
        guard let day = item as? LibraryDay else { return shownDays[index] }
        return day.entries[index]
    }

    func outlineView(_ v: NSOutlineView, isItemExpandable item: Any) -> Bool { item is LibraryDay }
    func outlineView(_ v: NSOutlineView, isGroupItem item: Any) -> Bool { item is LibraryDay }
    func outlineView(_ v: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is LibraryEntry }

    func outlineView(_ v: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = v.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
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
            c.imageView = icon
            c.textField = t
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                t.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                t.centerYAnchor.constraint(equalTo: c.centerYAnchor),
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
            switch spec.tint {
            case .orange: cell.imageView?.contentTintColor = .systemOrange
            case .blue: cell.imageView?.contentTintColor = .systemBlue
            case .purple: cell.imageView?.contentTintColor = .systemPurple
            }
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
            cell.textField?.attributedStringValue = text
        }
        return cell
    }

    // MARK: test kit (mirrors the Settings pane harness)

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

    // Selection-driven state, readable by selftests: drive rows like a user, assert the derivation
    // (player bar visibility, lazy load, resets) without audible playback.
    func selectForTest(_ e: LibraryEntry?) { showEntry(e) }
    var playerBarHiddenForTest: Bool { playerBar.isHidden }
    var playerActiveForTest: Bool { player != nil }
    var openEnabledForTest: Bool { openBtn.isEnabled }
    var docTextForTest: String { textView.string }
    var clockTextForTest: String { clockLabel.stringValue }
    var seekMaxForTest: Double { seekSlider.maxValue }
    // Increment-2 hooks: header actions + seek links, driven like a user but without panels/audio.
    var exportEnabledForTest: Bool { exportBtn.isEnabled }
    var rerunButtonTitleForTest: String? { rerunBtn.isHidden ? nil : rerunBtn.title }
    var rerunSpinningForTest: Bool { !rerunSpinner.isHidden }
    var rerunStatusForTest: String? { rerunStatus.isHidden ? nil : rerunStatus.stringValue }
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
