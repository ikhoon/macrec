import AppKit

// MARK: - shared health-row rendering (the Status window + the main window's Status pane)

/// The traffic-light color for a health level — one mapping, every surface.
func healthLevelColor(_ level: HealthLevel) -> NSColor {
    switch level {
    case .ok: return .systemGreen
    case .warn: return .systemOrange
    case .bad: return .systemRed
    }
}

/// The button label for a health action — one mapping for every surface (the selector differs).
func healthActionTitle(_ action: HealthAction) -> String? {
    switch action {
    case .none: return nil
    case .grantPermissions: return "Grant…"
    case .openSettings: return "Settings…"
    case .retrySummary: return "Retry"
    case .testCapture: return "Test…"
    case .showLog: return "Open log"
    case .openNotificationSettings: return "Settings…"
    }
}

/// One health row: status dot + title + wrapped detail + an optional action button. Shared so the
/// Status window and the main window's Status pane can never drift apart visually.
func makeHealthRowView(_ row: HealthRow, actionTitle: String?, target: AnyObject?, action: Selector?,
                       tag: Int = -1) -> NSView {
    let dot = NSView()
    dot.wantsLayer = true
    dot.translatesAutoresizingMaskIntoConstraints = false
    dot.layer?.cornerRadius = 4
    dot.layer?.backgroundColor = healthLevelColor(row.level).cgColor
    dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
    dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

    let title = NSTextField(labelWithString: row.title)
    title.font = .systemFont(ofSize: 13, weight: .medium)
    // Wrapping detail, capped to a readable measure — a single-line label's compression resistance
    // beats the window's set size and once forced the window ~950 pt wide.
    let detail = wrappingCaption(row.detail)
    detail.widthAnchor.constraint(lessThanOrEqualToConstant: 430).isActive = true
    let text = NSStackView(views: [title, detail])
    text.orientation = .vertical
    text.spacing = 1
    text.alignment = .leading

    let views: [NSView]
    if let actionTitle, let target, let action {
        let b = NSButton(title: actionTitle, target: target, action: action)
        b.tag = tag
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.setContentHuggingPriority(.required, for: .horizontal)
        views = [dot, text, NSView(), b]
    } else {
        views = [dot, text]
    }
    let h = NSStackView(views: views)
    h.orientation = .horizontal
    h.spacing = 8
    // firstBaseline: a center-aligned dot/button drifts into the middle of a wrapped paragraph.
    h.alignment = .firstBaseline
    h.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
    h.translatesAutoresizingMaskIntoConstraints = false
    text.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return h
}
