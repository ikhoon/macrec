import AppKit
import Foundation

// MARK: - pure month-grid decisions (selftested)

/// The weeks of `month` ("yyyy-MM") as rows of seven "yyyy-MM-dd" cells, nil-padded before the 1st
/// and after the last day, honoring the calendar's firstWeekday. Pure — the view just renders it.
func monthGrid(_ month: String, calendar: Calendar = .current) -> [[String?]] {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM"
    guard let first = f.date(from: month),
          let days = calendar.range(of: .day, in: .month, for: first) else { return [] }
    let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
    var cells = [String?](repeating: nil, count: lead)
    for d in days { cells.append(String(format: "%@-%02d", month, d)) }
    while cells.count % 7 != 0 { cells.append(nil) }
    return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0 ..< $0 + 7]) }
}

/// `month` ("yyyy-MM") shifted by `by` months — the ‹ › navigation. Pure.
func monthShift(_ month: String, by: Int, calendar: Calendar = .current) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM"
    guard let d = f.date(from: month), let s = calendar.date(byAdding: .month, value: by, to: d) else { return month }
    return f.string(from: s)
}

/// Weekday header letters starting at the calendar's firstWeekday (e.g. S M T W T F S). Pure.
func weekdayHeaders(calendar: Calendar = .current) -> [String] {
    let syms = calendar.veryShortWeekdaySymbols
    let start = calendar.firstWeekday - 1
    return (0 ..< 7).map { syms[(start + $0) % syms.count] }
}

/// The grid's working calendar: always GREGORIAN — the library's "yyyy-MM-dd" stems are Gregorian
/// by construction, and a Buddhist/Japanese system calendar would mis-place every cell — with
/// English symbols to match the app's UI language, keeping the user's week start and timezone.
func libraryGridCalendar(from current: Calendar = .current) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.locale = Locale(identifier: "en_US_POSIX")
    c.firstWeekday = current.firstWeekday
    c.timeZone = current.timeZone
    return c
}

// MARK: - the calendar sidebar (dumb renderer of monthGrid)

/// A compact month calendar above the Library list: recorded days read accent, empty days dim;
/// clicking a day filters the list to it, re-clicking (or the ✕ chip) clears. All decisions
/// (grid, shift, filter) are pure and selftested; this view only materializes them into buttons.
final class LibraryCalendarView: NSView {
    /// The picked day ("yyyy-MM-dd"), or nil when the pick was cleared. The window owns the filter.
    var onPick: ((String?) -> Void)?

    private(set) var month: String = "" // "yyyy-MM" currently shown
    private(set) var selectedDay: String?
    /// True once the user pages with ‹ › — until then the window keeps the month on the newest data
    /// (a recording landing in a new month must move the grid; a browsed month must not snap back).
    private(set) var userNavigated = false
    private var contentDays: Set<String> = []
    private var today: String = ""
    private let cal = libraryGridCalendar()
    private let monthLabel = NSTextField(labelWithString: "")
    private let grid = NSStackView()
    private let clearBtn = NSButton(title: "", target: nil, action: nil)
    private let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM yyyy"
        return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let prev = NSButton(title: "‹", target: self, action: #selector(prevMonth))
        prev.setAccessibilityLabel("Previous month")
        let next = NSButton(title: "›", target: self, action: #selector(nextMonth))
        next.setAccessibilityLabel("Next month")
        for b in [prev, next] {
            b.isBordered = false
            b.font = .systemFont(ofSize: 14, weight: .semibold)
            // ≥ the 12 pt layout-guard floor for text controls — and a decent click target.
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true
            b.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }
        monthLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        monthLabel.alignment = .center
        let header = NSStackView(views: [prev, monthLabel, next])
        header.orientation = .horizontal
        header.distribution = .equalCentering
        grid.orientation = .vertical
        grid.spacing = 1
        grid.alignment = .centerX
        // The clear chip: the ONLY always-reachable way out of a day filter once the user pages to
        // another month (the picked cell — the toggle — is then off-screen).
        clearBtn.bezelStyle = .inline
        clearBtn.controlSize = .small
        clearBtn.font = .systemFont(ofSize: 10)
        clearBtn.target = self
        clearBtn.action = #selector(clearTapped)
        clearBtn.setAccessibilityLabel("Clear the day filter")
        let v = NSStackView(views: [header, grid, clearBtn])
        v.orientation = .vertical
        v.spacing = 4
        v.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 6, right: 8)
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor),
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { nil }

    /// Re-render for a month + the days that have content. `selectedDay` survives month flips so
    /// browsing other months never silently drops an active filter.
    func load(month: String, contentDays: Set<String>, selectedDay: String?, today: String) {
        self.month = month
        self.contentDays = contentDays
        self.selectedDay = selectedDay
        self.today = today
        rebuild()
    }

    /// Window-driven selection sync (the tray deep-link clears the filter): the view's own copy must
    /// follow, or the highlight lies AND the next click toggles the stale value into a dead first click.
    func syncSelection(_ day: String?) {
        guard selectedDay != day else { return }
        selectedDay = day
        rebuild()
    }

    /// Appearance/accent changes re-resolve the layer colors (a CGColor is captured statically).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if !month.isEmpty { rebuild() }
    }

    @objc private func prevMonth() { flip(by: -1) }
    @objc private func nextMonth() { flip(by: 1) }
    private func flip(by: Int) {
        userNavigated = true
        month = monthShift(month, by: by, calendar: cal)
        rebuild()
    }

    @objc private func dayTapped(_ sender: NSButton) {
        guard let day = sender.identifier?.rawValue, !day.isEmpty else { return }
        selectedDay = selectedDay == day ? nil : day // toggle: re-clicking the picked day clears it
        rebuild()
        onPick?(selectedDay)
    }

    @objc private func clearTapped() {
        guard selectedDay != nil else { return }
        selectedDay = nil
        rebuild()
        onPick?(nil)
    }

    private func rebuild() {
        // "yyyy-MM" → "MMM yyyy" via the grid's own first real day (no second parsing convention).
        monthLabel.stringValue = month
        if let first = monthGrid(month, calendar: cal).joined().compactMap({ $0 }).first {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            if let d = f.date(from: first) { monthLabel.stringValue = titleFormatter.string(from: d) }
        }
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let headerRow = NSStackView(views: weekdayHeaders(calendar: cal).map { s in
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 9, weight: .semibold)
            l.textColor = .tertiaryLabelColor
            l.alignment = .center
            l.widthAnchor.constraint(equalToConstant: 24).isActive = true
            l.heightAnchor.constraint(equalToConstant: 12).isActive = true   // the layout-guard floor
            return l
        })
        headerRow.orientation = .horizontal
        headerRow.spacing = 1
        grid.addArrangedSubview(headerRow)
        // Always SIX week rows (pad short months with empty rows): a 5-week month would otherwise
        // change the calendar's height and make the list below jump ~23 px on every ‹ › page.
        var weeks = monthGrid(month, calendar: cal)
        while weeks.count < 6 { weeks.append([String?](repeating: nil, count: 7)) }
        for week in weeks {
            let row = NSStackView(views: week.map { day in dayButton(day) })
            row.orientation = .horizontal
            row.spacing = 1
            grid.addArrangedSubview(row)
        }
        clearBtn.isHidden = selectedDay == nil
        clearBtn.title = "✕ \(selectedDay ?? "")"
        clearBtn.toolTip = "Show every day again"
    }

    private func dayButton(_ day: String?) -> NSView {
        guard let day else {
            let pad = NSView()
            pad.widthAnchor.constraint(equalToConstant: 24).isActive = true
            pad.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return pad
        }
        let has = contentDays.contains(day)
        let b = NSButton(title: String(Int(day.suffix(2)) ?? 0), target: self, action: #selector(dayTapped(_:)))
        b.identifier = NSUserInterfaceItemIdentifier(day)
        b.isBordered = false
        b.font = .systemFont(ofSize: 11, weight: day == today ? .bold : .regular)
        // MONOCHROME (no accent): recorded days read at full label strength + medium weight, empty
        // days recede to tertiary; the picked day is an inverted gray pill; today wears a gray ring.
        b.contentTintColor = day == selectedDay ? .windowBackgroundColor
            : has ? .labelColor : .tertiaryLabelColor
        if has, day != selectedDay { b.font = .systemFont(ofSize: 11, weight: day == today ? .bold : .medium) }
        b.wantsLayer = true
        b.layer?.cornerRadius = 4
        b.layer?.backgroundColor = day == selectedDay
            ? NSColor.labelColor.withAlphaComponent(0.85).cgColor : nil
        if day == today, day != selectedDay {
            b.layer?.borderWidth = 1
            b.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.35).cgColor
        }
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        b.toolTip = has ? "\(day) — show only this day's recordings" : "\(day) — no recordings"
        // VoiceOver hears the DATE and whether it holds recordings, not a bare number.
        b.setAccessibilityLabel("\(day), \(has ? "has recordings" : "no recordings")")
        return b
    }

    // Selftest hooks: drive the RENDERED controls (performClick on the real button — a fabricated
    // action could pass with no visible control wired at all), read the state back.
    @discardableResult
    func pickForTest(_ day: String) -> Bool {
        let hit = grid.arrangedSubviews.dropFirst()
            .flatMap { ($0 as? NSStackView)?.arrangedSubviews ?? [] }
            .compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == day }
        guard let hit else { return false }   // the date isn't on the shown month's grid
        hit.performClick(nil)
        return true
    }

    /// performClick the ✕ chip; false when it isn't visible (no active filter to clear).
    @discardableResult
    func clickClearForTest() -> Bool {
        guard !clearBtn.isHidden else { return false }
        clearBtn.performClick(nil)
        return true
    }

    func flipForTest(by: Int) { flip(by: by) }
    var monthForTest: String { month }
    func dayButtonCountForTest() -> Int {
        grid.arrangedSubviews.dropFirst().flatMap { ($0 as? NSStackView)?.arrangedSubviews ?? [] }
            .compactMap { $0 as? NSButton }.count
    }

    /// Week rows currently rendered (excluding the weekday header) — pinned at a constant 6 so the
    /// list below never jumps when paging between 5- and 6-week months.
    var weekRowCountForTest: Int { grid.arrangedSubviews.count - 1 }
}
