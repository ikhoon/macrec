import AppKit

// MARK: - pure decisions (selftested)

/// The section header for a day: Today/Yesterday read faster than dates for the two days that matter.
func libraryDayLabel(day: String, today: String, yesterday: String) -> String {
    day == today ? "Today — \(day)" : day == yesterday ? "Yesterday — \(day)" : day
}

/// One row's display text. The digest row names itself; a transcript row is time + title, and it
/// carries a summary marker so "which meetings got summarized" is visible without clicking.
func libraryRowText(_ e: LibraryEntry) -> String {
    if e.kind == .digest { return "Daily digest" }
    let name = e.title ?? "(untitled)"
    let mark = e.summaryURL != nil ? "  ✓ summary" : ""
    return "\(e.time ?? "--:--")  \(name)\(mark)"
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
final class LibraryWindow: NSObject, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let shared = LibraryWindow()
    private var window: NSWindow?
    private let outline = NSOutlineView()
    private let searchField = NSSearchField()
    private let textView = NSTextView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let docPicker = NSSegmentedControl(labels: ["Transcript", "Summary"],
                                               trackingMode: .selectOne, target: nil, action: nil)
    private let openBtn = NSButton(title: "Open", target: nil, action: nil)
    private let revealBtn = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    private let emptyLabel = NSTextField(wrappingLabelWithString:
        "Nothing here yet — transcripts appear as meetings are recorded.")

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
        let w = EditKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 540),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        w.title = "macrec library"
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.minSize = NSSize(width: 640, height: 360)
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

        let right = NSStackView(views: [head, rightScroll])
        right.orientation = .vertical
        right.spacing = 0
        right.distribution = .fill
        head.setContentHuggingPriority(.required, for: .vertical)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(leftScroll)
        split.addArrangedSubview(right)
        leftScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        rightScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

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
    /// header text, picker visibility, button enablement, the text itself — derives from here, so a
    /// clickable control can never point at a document that isn't there.
    private func showEntry(_ entry: LibraryEntry?) {
        selected = entry
        guard let e = entry else {
            headerLabel.stringValue = ""
            docPicker.isHidden = true
            openBtn.isEnabled = false
            revealBtn.isEnabled = false
            textView.string = ""
            return
        }
        let day = libraryDayLabel(day: e.day, today: Self.dayString(Date()),
                                  yesterday: Self.dayString(Date().addingTimeInterval(-86400)))
        headerLabel.stringValue = e.kind == .digest
            ? "\(day) · Daily digest"
            : "\(day) · \(libraryRowText(e))"
        docPicker.isHidden = e.summaryURL == nil
        if docPicker.selectedSegment < 0 { docPicker.selectedSegment = 0 }
        openBtn.isEnabled = true
        revealBtn.isEnabled = true
        loadDoc()
    }

    /// The URL the right pane is currently showing (transcript or its summary).
    private func currentDocURL() -> URL? {
        guard let e = selected else { return nil }
        if !docPicker.isHidden, docPicker.selectedSegment == 1, let s = e.summaryURL { return s }
        return e.url
    }

    private func loadDoc() {
        guard let url = currentDocURL() else { return }
        // Transcripts are text; cap the read so a runaway file can't beachball the window.
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            let capped = data.prefix(2_000_000)
            textView.string = String(decoding: capped, as: UTF8.self)
                + (data.count > capped.count ? "\n\n… (truncated view — Open shows the full file)" : "")
        } else {
            textView.string = "(could not read \(url.path))"
        }
        textView.scrollToBeginningOfDocument(nil)
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
        return (item as! LibraryDay).entries[index]
    }

    func outlineView(_ v: NSOutlineView, isItemExpandable item: Any) -> Bool { item is LibraryDay }
    func outlineView(_ v: NSOutlineView, isGroupItem item: Any) -> Bool { item is LibraryDay }
    func outlineView(_ v: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is LibraryEntry }

    func outlineView(_ v: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = v.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
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
        if let day = item as? LibraryDay {
            cell.textField?.stringValue = libraryDayLabel(
                day: day.day, today: Self.dayString(Date()),
                yesterday: Self.dayString(Date().addingTimeInterval(-86400)))
            cell.textField?.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            cell.textField?.textColor = .secondaryLabelColor
        } else if let e = item as? LibraryEntry {
            cell.textField?.stringValue = libraryRowText(e)
            cell.textField?.font = NSFont.systemFont(ofSize: 12)
            cell.textField?.textColor = .labelColor
        }
        return cell
    }

    // MARK: test kit (mirrors the Settings pane harness)

    /// Inject fixture data and build the window without touching the user's folders.
    func loadFixtureForTest(_ days: [LibraryDay]) {
        fixtureDays = days
        if window == nil { build() }
        refresh()
        // Fixture rows exist but nothing is selected yet — select the first entry like a user would.
        if let first = shownDays.first?.entries.first { showEntry(first) }
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
