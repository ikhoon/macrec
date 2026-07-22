import AppKit

// MARK: - the Today dashboard window (desktop app, increment 1 — see DESIGN-today.md)

/// A glanceable health panel: every silent-failure class as a visible red row with a fix button.
/// The window is a dumb renderer of `todayHealth`'s pure output; all verdicts live in that
/// function and are selftested. Signals are re-sampled on a 1 Hz timer WHILE VISIBLE only, plus on
/// focus and on transcript-saved — a snapshot goes stale the moment it's taken.
final class TodayWindow: NSObject, NSWindowDelegate {
    static let shared = TodayWindow()
    private var window: NSWindow?
    private let overallLabel = NSTextField(labelWithString: "")
    private let overallDot = NSView()
    private let stack = NSStackView()
    private var timer: Timer?

    /// Injected by the app so the panel can sample live engine state and fire actions. In tests
    /// these stay nil and `sampleForTest` drives the view directly.
    var sampleInputs: (() -> HealthInputs)?
    var onGrant: (() -> Void)?
    var onOpenSettings: ((String) -> Void)?
    var onRetrySummary: (() -> Void)?
    var onTestCapture: (() -> Void)?
    var onShowLog: (() -> Void)?
    var onOpenNotificationSettings: (() -> Void)?
    var onWillRefresh: (() -> Void)? // let the app refresh cheap-but-off-main caches before a sample

    func toggle() {
        if let w = window, w.isVisible { w.orderOut(nil) } else { show() }
    }

    func show() {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        render()
        startTimer()
    }

    /// Engine hook: a transcript just landed — the Today counts changed.
    func noteChanged() { if let w = window, w.isVisible { render() } }
    var isVisible: Bool { window?.isVisible ?? false }   // #32: skip background alerts while it's open

    func windowDidBecomeKey(_ notification: Notification) { render() }
    func windowWillClose(_ notification: Notification) { stopTimer() }
    // Stop ticking when the window can't be seen — minimize/hide don't fire windowWillClose.
    func windowDidMiniaturize(_ notification: Notification) { stopTimer() }
    func windowDidDeminiaturize(_ notification: Notification) { startTimer(); render() }
    private func stopTimer() { timer?.invalidate(); timer = nil }

    // MARK: build

    private func build() {
        let w = EditKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        w.title = "macrec status"
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.minSize = NSSize(width: 380, height: 320)
        // "todayWindow2": the pre-wrap builds autosaved the ~950 pt width the stretch bug FORCED (the
        // user never chose it), so restoring under the old key would reopen wide forever. A new key
        // abandons the poisoned frame once; resizes from here on persist normally under the new name.
        w.setFrameAutosaveName("todayWindow2")
        let content = NSView()

        // Header: a big status dot + the overall one-liner (worst row wins).
        overallDot.wantsLayer = true
        overallDot.translatesAutoresizingMaskIntoConstraints = false
        overallDot.layer?.cornerRadius = 7
        overallLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        overallLabel.lineBreakMode = .byTruncatingTail
        // Truncate rather than stretch: the header one-liner must never force the window wide either.
        overallLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [overallDot, overallLabel])
        header.orientation = .horizontal
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 8, right: 16)
        header.translatesAutoresizingMaskIntoConstraints = false
        overallDot.widthAnchor.constraint(equalToConstant: 14).isActive = true
        overallDot.heightAnchor.constraint(equalToConstant: 14).isActive = true

        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 12, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // No scroll view: increment 1 has four groups (~11 rows) that fit the window. The stack
        // pins directly under the header and grows downward; if the list ever overflows, wrap it in
        // a flipped scroll view then (a non-flipped NSScrollView floats short content to the bottom).
        content.addSubview(header)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: header.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -12),
        ])
        w.contentView = content
        window = w
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.render() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: render

    private var fixtureRows: [HealthRow]?
    private var renderedRows: [HealthRow]? // last rendered — skip the rebuild when unchanged

    private func render() {
        onWillRefresh?()
        let rows = fixtureRows ?? sampleInputs.map { todayHealth($0()) } ?? []
        let overall = overallHealth(rows)
        overallLabel.stringValue = overall.line
        overallDot.layer?.backgroundColor = Self.color(overall.level).cgColor

        // Rebuild the row views ONLY when the rows actually changed — otherwise a 1 Hz teardown
        // would drop a click landing on a fix button mid-tick (review finding), and churn layout.
        guard rows != renderedRows else { return }
        renderedRows = rows
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var lastGroup = ""
        for row in rows {
            if row.group != lastGroup {
                lastGroup = row.group
                let g = NSTextField(labelWithString: row.group.uppercased())
                g.font = .systemFont(ofSize: 10, weight: .bold)
                g.textColor = .tertiaryLabelColor
                let wrap = NSStackView(views: [g])
                wrap.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 2, right: 0)
                stack.addArrangedSubview(wrap)
                wrap.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            }
            stack.addArrangedSubview(rowView(row))
        }
    }

    private func rowView(_ row: HealthRow) -> NSView {
        let a = actionButton(row.action)
        return makeHealthRowView(row, actionTitle: a?.0, target: a == nil ? nil : self, action: a?.1)
    }

    private func actionButton(_ action: HealthAction) -> (String, Selector)? {
        // Titles come from the SHARED mapping (healthActionTitle) so this window and the main
        // window's Status pane can never label the same action differently; only selectors differ.
        let sel: Selector?
        switch action {
        case .none: sel = nil
        case .grantPermissions: sel = #selector(doGrant)
        case .openSettings: sel = #selector(doSettings)
        case .retrySummary: sel = #selector(doRetry)
        case .testCapture: sel = #selector(doTest)
        case .showLog: sel = #selector(doShowLog)
        case .openNotificationSettings: sel = #selector(doNotifSettings)
        }
        guard let sel, let title = healthActionTitle(action) else { return nil }
        return (title, sel)
    }

    // The action row is stashed so the @objc handlers know which pane/target to hit.
    private var lastRows: [HealthRow] { fixtureRows ?? sampleInputs.map { todayHealth($0()) } ?? [] }

    @objc private func doGrant() { onGrant?() }
    @objc private func doSettings() {
        let pane = lastRows.compactMap { r -> String? in
            if case .openSettings(let p) = r.action { return p }; return nil
        }.first
        onOpenSettings?(pane ?? "General")
    }

    @objc private func doRetry() { onRetrySummary?() }
    @objc private func doTest() { onTestCapture?() }
    @objc private func doShowLog() { onShowLog?() }
    @objc private func doNotifSettings() { onOpenNotificationSettings?() }

    private static func color(_ level: HealthLevel) -> NSColor { healthLevelColor(level) }

    // MARK: test kit (mirrors LibraryWindow)

    /// Inject fixture rows and build the window without sampling the live app.
    func loadFixtureForTest(_ rows: [HealthRow]) {
        fixtureRows = rows
        renderedRows = nil   // force a rebuild even if the previous fixture matched
        if window == nil { build() }
        render()
    }

    /// Which action button (if any) a given fixture row rendered — proves the window maps
    /// HealthAction to the right control (not just that the pure function returned an action).
    /// The title label sits in a nested vertical sub-stack, so search each row subtree.
    func actionButtonTitleForTest(rowTitle: String) -> String? {
        func labels(_ v: NSView) -> [String] {
            ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(labels)
        }
        func buttons(_ v: NSView) -> [String] {
            ((v as? NSButton).map { [$0.title] } ?? []) + v.subviews.flatMap(buttons)
        }
        for row in stack.arrangedSubviews where labels(row).contains(rowTitle) {
            return buttons(row).first
        }
        return nil
    }

    /// AUTOMATED LAYOUT GUARD (selftest): any control collapsed to ~zero. Runs at the min window
    /// size too — a control that fits at 480×560 can still clip at the 380×320 minimum.
    func layoutIssuesAtMinSize() -> [String] { layoutIssues(size: window?.minSize ?? NSSize(width: 380, height: 320)) }

    func layoutIssues(size: NSSize = NSSize(width: 480, height: 560)) -> [String] {
        guard let win = window, let content = win.contentView else { return ["today: no window"] }
        win.setContentSize(size)
        content.layoutSubtreeIfNeeded()
        var issues: [String] = []
        func walk(_ v: NSView) {
            if v.isHidden || v is NSScroller { return }
            if v is NSControl {
                let f = v.convert(v.bounds, to: content)
                if f.width < 3 || f.height < 3 {
                    issues.append("today: \(type(of: v)) collapsed to \(f)")
                }
            }
            v.subviews.forEach(walk)
        }
        walk(content)
        return issues
    }

    /// REGRESSION SEAM (selftest): the laid-out height of the detail label containing `fragment`, at the
    /// default content size. A SINGLE-LINE detail is the stretch bug — its >500 intrinsic priority made
    /// the onscreen window grow to the longest sentence (~950 pt, user: "가로로만 겁내 길어"). That window
    /// growth only happens in AppKit's onscreen layout pass, which a headless test cannot run — so the
    /// guard pins the CAUSE instead: the long detail must WRAP (≥ 2 line heights) at the set width.
    func detailHeightForTest(containing fragment: String,
                             at size: NSSize = NSSize(width: 480, height: 560)) -> CGFloat {
        guard let win = window, let content = win.contentView else { return -1 }
        win.setContentSize(size)
        content.layoutSubtreeIfNeeded()
        func find(_ v: NSView) -> NSTextField? {
            if let t = v as? NSTextField, t.stringValue.contains(fragment) { return t }
            for sub in v.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        return find(content)?.frame.height ?? -1
    }

    /// UI TEST KIT (see `macrec today-snapshot`): render the fixture-filled window to a PNG.
    func snapshot(to dir: URL) -> [URL] {
        guard let win = window, let content = win.contentView else { return [] }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        win.setContentSize(NSSize(width: 480, height: 560))
        content.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        let bounds = content.bounds
        guard bounds.width > 1, bounds.height > 1 else { return [] }
        let img = NSImage(size: bounds.size)
        img.lockFocus()
        win.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: bounds.size).fill()
            if let ctx = NSGraphicsContext.current { content.displayIgnoringOpacity(bounds, in: ctx) }
        }
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              !snapshotIsBlank(rep), let png = rep.representation(using: .png, properties: [:]) else { return [] }
        let url = dir.appendingPathComponent("today.png")
        try? png.write(to: url)
        return [url]
    }
}
