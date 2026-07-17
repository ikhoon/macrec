import AppKit
import AVFoundation

// MARK: - pure decisions (selftested)

/// The section header for a day: Today/Yesterday read faster than dates for the two days that matter.
func libraryDayLabel(day: String, today: String, yesterday: String) -> String {
    day == today ? "Today — \(day)" : day == yesterday ? "Yesterday — \(day)" : day
}

/// One row's visual spec: a leading KIND icon (digest / meeting / audio-only read apart at a
/// glance), the text, and trailing status icons ("summarized" sparkles, "audio kept" waveform).
/// Pure so the icon/text decisions are selftested; the cell just materializes SF Symbols.
struct LibraryRowSpec: Equatable {
    var icon: String // SF Symbol name — the entry's kind
    var text: String
    var trailing: [String] // SF Symbol names — what else exists for this entry
}

func libraryRowSpec(_ e: LibraryEntry) -> LibraryRowSpec {
    if e.kind == .digest { return LibraryRowSpec(icon: "newspaper", text: "Daily digest", trailing: []) }
    let text = "\(e.time ?? "--:--")  \(e.title ?? "(untitled)")"
    if e.kind == .audio { return LibraryRowSpec(icon: "waveform", text: text, trailing: []) }
    var trailing: [String] = []
    if e.summaryURL != nil { trailing.append("sparkles") }
    if e.audioURL != nil { trailing.append("waveform") }
    return LibraryRowSpec(icon: "text.bubble", text: text, trailing: trailing)
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
    NSSplitViewDelegate, AVAudioPlayerDelegate {
    static let shared = LibraryWindow()
    private var window: NSWindow?
    private let outline = NSOutlineView()
    private let searchField = NSSearchField()
    private let textView = NSTextView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let docPicker = NSSegmentedControl(labels: ["Summary", "Transcript"],
                                               trackingMode: .selectOne, target: nil, action: nil)
    private let openBtn = NSButton(title: "Open", target: nil, action: nil)
    private let revealBtn = NSButton(title: "Reveal in Finder", target: nil, action: nil)
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

        let refreshBtn = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        refreshBtn.bezelStyle = .rounded
        let bar = NSStackView(views: [searchField, refreshBtn])
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
        for b in [openBtn, revealBtn] { b.bezelStyle = .rounded }
        let head = NSStackView(views: [headerLabel, NSView(), docPicker, openBtn, revealBtn])
        head.orientation = .horizontal
        head.spacing = 8
        head.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 6, right: 10)
        headerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        textView.isEditable = false
        textView.isSelectable = true
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

        let right = NSStackView(views: [head, playerBar, rightScroll])
        right.orientation = .vertical
        right.spacing = 0
        right.distribution = .fill
        head.setContentHuggingPriority(.required, for: .vertical)
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
    }

    // MARK: data → view

    @objc private func filterChanged() { applyFilter() }
    @objc private func refreshClicked() { refresh() }

    private func applyFilter() {
        shownDays = libraryFiltered(allDays, filter: searchField.stringValue)
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        emptyLabel.isHidden = !shownDays.isEmpty
        emptyLabel.stringValue = allDays.isEmpty
            ? "Nothing here yet — transcripts appear as meetings are recorded."
            : "No match for the current filter."
        // Keep the preview in sync: the selected file may be gone after a rescan.
        if let sel = selected,
           !shownDays.contains(where: { $0.entries.contains(sel) }) { showEntry(nil) }
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
        playerBar.isHidden = e.audioURL == nil
        openBtn.isEnabled = true
        revealBtn.isEnabled = true
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
            textView.textStorage?.setAttributedString(MarkdownRender.render(text, baseURL: url))
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
            let font = NSFont.systemFont(ofSize: 12)
            let text = NSMutableAttributedString(string: spec.text, attributes: [
                .font: font, .foregroundColor: NSColor.labelColor,
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

    // Selection-driven state, readable by selftests: drive rows like a user, assert the derivation
    // (player bar visibility, lazy load, resets) without audible playback.
    func selectForTest(_ e: LibraryEntry?) { showEntry(e) }
    var playerBarHiddenForTest: Bool { playerBar.isHidden }
    var playerActiveForTest: Bool { player != nil }
    var openEnabledForTest: Bool { openBtn.isEnabled }
    var docTextForTest: String { textView.string }
    var clockTextForTest: String { clockLabel.stringValue }
    var seekMaxForTest: Double { seekSlider.maxValue }

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
            if v is NSControl || v is NSTextView {
                let f = visibleRect(v)
                if f.isEmpty { return }   // scrolled out of view — nothing to assert
                let name = "\(type(of: v))(\((v as? NSButton)?.title ?? (v as? NSTextField)?.stringValue ?? ""))"
                if f.width < 4 || f.height < 4 { issues.append("library: \(name) collapsed to \(f)") }
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
    func snapshot(to dir: URL) -> [URL] {
        guard let win = window, let content = win.contentView else { return [] }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        win.setContentSize(NSSize(width: 860, height: 540))
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
