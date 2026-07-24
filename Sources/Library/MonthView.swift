import AppKit

// MARK: - the big month view (Calendar.app-style: a full-size grid with each day's recordings as chips)

/// The month grid for the LEFT split pane: every day cell lists that day's recordings as chips; clicking
/// a chip asks the window to open it in the RIGHT doc pane (a side panel, not a popover). Navigation + the
/// weekday header + today's disc mirror the compact sidebar calendar; the layout math is the same pure
/// monthGrid/monthShift/weekday helpers. Monochrome by rule — the only color is a small kind dot per chip.
final class MonthCalendarView: NSView {
    var onPickEntry: ((LibraryEntry) -> Void)?   // a chip → the window shows this entry in the doc pane
    var onPickDay: ((String) -> Void)?           // "+N more" → the window drops to that day's list
    var onMonthChanged: ((String) -> Void)?

    private(set) var month = "" // "yyyy-MM"
    private(set) var userNavigated = false
    private var entriesByDay: [String: [LibraryEntry]] = [:]
    private var today = ""

    private let cal = libraryGridCalendar()
    private let monthLabel = NSTextField(labelWithString: "")
    private let grid = NSStackView()
    private let titleFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMMM yyyy"; return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        monthLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        let prev = navButton("chevron.left", #selector(prevMonth))
        let next = navButton("chevron.right", #selector(nextMonth))
        let todayBtn = NSButton(title: "Today", target: self, action: #selector(goToday))
        todayBtn.bezelStyle = .rounded
        todayBtn.controlSize = .small
        let header = NSStackView(views: [monthLabel, NSView(), prev, next, todayBtn])
        header.orientation = .horizontal
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        grid.orientation = .vertical
        grid.spacing = 0
        grid.distribution = .fillEqually   // six EQUAL week rows fill the height
        grid.translatesAutoresizingMaskIntoConstraints = false

        // The weekday header is static — build it ONCE, outside the fillEqually week grid.
        let weekdayRow = NSStackView(views: weekdayHeaders(calendar: cal).map { s in
            let l = NSTextField(labelWithString: s.uppercased())
            l.font = .systemFont(ofSize: 10, weight: .semibold)
            l.textColor = .tertiaryLabelColor
            l.alignment = .center
            l.setContentHuggingPriority(.defaultLow, for: .horizontal) // fillEqually stretches it to its column
            return l
        })
        weekdayRow.orientation = .horizontal
        weekdayRow.distribution = .fillEqually
        weekdayRow.spacing = 0
        weekdayRow.translatesAutoresizingMaskIntoConstraints = false

        // Pin each band directly to the view's edges — relying on a parent stack's alignment left the
        // weekday letters bunched to one side (the stack hugged the row to its intrinsic width).
        addSubview(header); addSubview(weekdayRow); addSubview(grid)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            weekdayRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            weekdayRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            weekdayRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            grid.topAnchor.constraint(equalTo: weekdayRow.bottomAnchor, constant: 2),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Stroke the month grid as SINGLE hairlines (one line per boundary, not a doubled per-cell border) in
    /// a fixed thin gray that reads on both light and dark — drawn here rather than via layer colors, which
    /// froze to the wrong appearance. 7 equal columns × 6 equal rows over the grid's frame.
    override func layout() { super.layout(); needsDisplay = true }   // re-stroke the gridlines after a resize

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let f = grid.frame
        guard f.width > 1, f.height > 1 else { return }
        NSColor.gray.withAlphaComponent(0.28).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 0.5
        for c in 0...7 {   // vertical lines
            let x = (f.minX + f.width * CGFloat(c) / 7).rounded() + 0.25
            path.move(to: NSPoint(x: x, y: f.minY)); path.line(to: NSPoint(x: x, y: f.maxY))
        }
        for r in 0...6 {   // horizontal lines
            let y = (f.minY + f.height * CGFloat(r) / 6).rounded() + 0.25
            path.move(to: NSPoint(x: f.minX, y: y)); path.line(to: NSPoint(x: f.maxX, y: y))
        }
        path.stroke()
    }

    /// Captured layer cgColors (cell border, today disc, chip dots) don't auto-adapt — re-render on a
    /// live light/dark switch so they don't freeze to the old appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if !month.isEmpty { rebuild() }
    }

    /// Show `month`, keyed by the day → entries map. `today` gets the ring. Called by the window on every
    /// data/section change (a snapshot the moment it's taken — the window re-invokes on any change).
    func load(month: String, entriesByDay: [String: [LibraryEntry]], today: String) {
        self.month = month
        self.entriesByDay = entriesByDay
        self.today = today
        rebuild()
    }

    private func navButton(_ symbol: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        b.isBordered = false
        b.bezelStyle = .inline
        b.contentTintColor = .secondaryLabelColor
        return b
    }

    @objc private func prevMonth() { flip(by: -1) }
    @objc private func nextMonth() { flip(by: 1) }
    @objc private func goToday() {
        userNavigated = true
        month = String(today.prefix(7))
        rebuild()
        onMonthChanged?(month)
    }

    private func flip(by: Int) {
        userNavigated = true
        month = monthShift(month, by: by, calendar: cal)
        rebuild()
        onMonthChanged?(month)
    }

    private func rebuild() {
        monthLabel.stringValue = month
        if let first = monthGrid(month, calendar: cal).joined().compactMap({ $0 }).first {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            if let d = f.date(from: first) { monthLabel.stringValue = titleFormatter.string(from: d) }
        }
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Always SIX week rows so the grid height doesn't jump between 5- and 6-week months.
        var weeks = monthGrid(month, calendar: cal)
        while weeks.count < 6 { weeks.append([String?](repeating: nil, count: 7)) }
        for week in weeks {
            let row = NSStackView(views: week.map { dayCell($0) })
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 0
            grid.addArrangedSubview(row)
        }
    }

    private func dayCell(_ day: String?) -> NSView {
        let cell = NSView()
        cell.wantsLayer = true
        cell.layer?.masksToBounds = true   // a short cell (small window) must CLIP its chips, not spill into the next row
        // No border/background: the SINGLE hairline gridlines are stroked once in draw(); per-cell borders
        // doubled between neighbors (thick — user report) and an opaque dynamic-color fill froze to the
        // wrong appearance on a layer (black cells in light mode).
        cell.translatesAutoresizingMaskIntoConstraints = false
        // High, not required: six rows × ≥64 would fight the grid's pins when the window is dragged to its
        // 360-pt minimum (AppKit would log an unsatisfiable-constraints break). It yields before it conflicts.
        let h = cell.heightAnchor.constraint(greaterThanOrEqualToConstant: 64)
        h.priority = .defaultHigh
        h.isActive = true
        guard let day else { return cell } // a padding cell outside the month

        let num = NSTextField(labelWithString: String(Int(day.suffix(2)) ?? 0))
        num.font = .systemFont(ofSize: 11, weight: day == today ? .bold : .regular)
        num.textColor = day == today ? .labelColor : .secondaryLabelColor
        num.translatesAutoresizingMaskIntoConstraints = false
        if day == today {
            // Today's number wears a small filled disc (monochrome), like Calendar.app.
            num.textColor = .controlBackgroundColor
            let disc = NSView()
            disc.wantsLayer = true
            disc.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.85).cgColor
            disc.layer?.cornerRadius = 9
            disc.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(disc)
            cell.addSubview(num)
            NSLayoutConstraint.activate([
                disc.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
                disc.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                disc.widthAnchor.constraint(equalToConstant: 18),
                disc.heightAnchor.constraint(equalToConstant: 18),
                num.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
                num.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
            ])
        } else {
            cell.addSubview(num)
            NSLayoutConstraint.activate([
                num.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
                num.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            ])
        }

        let entries = entriesByDay[day] ?? []
        guard !entries.isEmpty else { return cell }
        let (chips, overflow) = monthCellChips(entries, max: 3)
        let stack = NSStackView(views: chips.map { chipButton($0) })
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        if overflow > 0 {
            let more = NSButton(title: "+\(overflow) more", target: self, action: #selector(overflowTapped(_:)))
            more.identifier = NSUserInterfaceItemIdentifier(day)
            more.isBordered = false
            more.font = .systemFont(ofSize: 10)
            more.contentTintColor = .secondaryLabelColor
            stack.addArrangedSubview(more)
        }
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cell.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        ])
        return cell
    }

    /// A chip carries its own entry — no side map to leak or clear (an ObjectIdentifier map accreted stale
    /// keys across every rebuild, and address reuse made that untestable). The button IS the source of truth.
    private final class ChipButton: NSButton { var entry: LibraryEntry? }

    private func chipButton(_ e: LibraryEntry) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2.5
        dot.layer?.backgroundColor = libraryTintColor(libraryRowSpec(e).tint).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 5).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 5).isActive = true

        let label = ChipButton(title: monthChipLabel(e), target: self, action: #selector(chipTapped(_:)))
        label.entry = e
        label.isBordered = false
        label.font = .systemFont(ofSize: 10)
        label.contentTintColor = .labelColor
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.setButtonType(.momentaryChange)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [dot, label])
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        dot.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    @objc private func chipTapped(_ sender: NSButton) {
        guard let e = (sender as? ChipButton)?.entry else { return }
        onPickEntry?(e)
    }

    @objc private func overflowTapped(_ sender: NSButton) {
        if let day = sender.identifier?.rawValue { onPickDay?(day) }
    }

    private func chipButtons() -> [ChipButton] {
        func walk(_ v: NSView) -> [ChipButton] { (v as? ChipButton).map { [$0] } ?? v.subviews.flatMap(walk) }
        return walk(self)
    }

    /// The "UI 깨짐" bug was chips of a short cell spilling onto the NEXT row. The structural guarantee
    /// against that, at ANY window size, is that every day cell CLIPS its contents. Count cells that do
    /// NOT clip — 0 means no cell can ever spill into a neighbor. (Deterministic, unlike frame probing a
    /// headless layout; "do 3 chips fit without clipping at a roomy size" is the snapshot's eyeball job.)
    func layoutIssuesForTest() -> Int {
        var issues = 0
        for row in grid.arrangedSubviews {
            for cell in (row as? NSStackView)?.arrangedSubviews ?? [] where cell.layer?.masksToBounds != true {
                issues += 1
            }
        }
        return issues
    }

    // Test hooks: drive the RENDERED chips/nav (a fabricated action could pass with nothing wired).
    var monthForTest: String { month }
    func flipForTest(by: Int) { flip(by: by) }
    func chipCountForTest() -> Int { chipButtons().count }
    @discardableResult
    func clickFirstChipForTest(onDay day: String) -> LibraryEntry? {
        guard let btn = chipButtons().first(where: { $0.entry?.day == day }) else { return nil }
        btn.performClick(nil)
        return btn.entry
    }
}
