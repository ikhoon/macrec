import AppKit

/// A window that routes the standard Cut/Copy/Paste/Select-All/Undo shortcuts to its first responder.
/// A menu-bar (accessory) app has no Edit menu, so without this a text field in an auxiliary window gets
/// no ⌘V/⌘C at all — the field editor never sees the key equivalent.
final class EditKeyWindow: NSWindow {
    /// Esc closes the window — every macrec aux window (Log, Library, Today) is an EditKeyWindow, so
    /// they all get it for free. cancelOperation is the standard Esc route; guard against a search
    /// field that wants Esc to just clear itself first (NSSearchField handles Esc as clear when it
    /// has text + focus, so this only fires when nothing consumed it).
    override func cancelOperation(_ sender: Any?) { close() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            let sel: Selector?
            switch event.charactersIgnoringModifiers {
            case "x": sel = #selector(NSText.cut(_:))
            case "c": sel = #selector(NSText.copy(_:))
            case "v": sel = #selector(NSText.paste(_:))
            case "a": sel = #selector(NSText.selectAll(_:))
            case "z": sel = Selector(("undo:"))
            default: sel = nil
            }
            if let sel, NSApp.sendAction(sel, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The log lines a filter keeps: case-insensitive substring match, or all lines when the filter is blank.
/// Pure + selftested (the window's rendering is just this plus a scroll).
func logLinesFiltered(_ all: [String], filter: String) -> [String] {
    let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
    return f.isEmpty ? all : all.filter { $0.lowercased().contains(f) }
}

/// A live view of the app's own log — the `elog` stream, tailed from `LogBuffer` — so debugging and
/// troubleshooting happen inside the app instead of hunting for launchd's redirected log file (whose path
/// the app never learns). Opened from the tray menu.
///
/// The log is noisy (the echo canceller prints often), so two controls make it usable: a filter that
/// keeps only matching lines, and an Auto-scroll toggle that doubles as pause — while it's on the view
/// tails the newest lines; turn it off to freeze the current text and read or select it.
final class LogWindow: NSObject, NSWindowDelegate {
    static let shared = LogWindow()
    private var window: NSWindow?
    private let textView = NSTextView()
    private let filterField = NSSearchField()
    private let autoScrollBox = NSButton(checkboxWithTitle: "Auto-scroll", target: nil, action: nil)
    private var timer: Timer?
    private var lastRenderedCount = -1
    private var lastFilter = "\u{0}"   // sentinel so the first render always runs

    func toggle() {
        if let w = window, w.isVisible { w.orderOut(nil) } else { show() }
    }

    func show() {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        render(force: true)
        startTimer()
    }

    private func build() {
        let w = EditKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        w.title = "macrec log"
        w.center()
        w.isReleasedWhenClosed = false   // we reuse the instance; releasing it would dangle `window`
        w.delegate = self
        w.minSize = NSSize(width: 480, height: 260)
        let content = NSView()

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(white: 0.09, alpha: 1)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = NSColor(white: 0.86, alpha: 1)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView

        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.placeholderString = "Filter (e.g. openai, keychain, error)"
        filterField.sendsSearchStringImmediately = true
        filterField.target = self
        filterField.action = #selector(filterChanged)

        autoScrollBox.translatesAutoresizingMaskIntoConstraints = false
        autoScrollBox.state = .on
        autoScrollBox.toolTip = "Tail the newest lines. Turn off to freeze the view and read or select."

        let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyShown))
        let clearBtn = NSButton(title: "Clear", target: self, action: #selector(clearLog))
        for b in [copyBtn, clearBtn] { b.bezelStyle = .rounded; b.translatesAutoresizingMaskIntoConstraints = false }

        let bar = NSStackView(views: [filterField, autoScrollBox, copyBtn, clearBtn])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        bar.translatesAutoresizingMaskIntoConstraints = false
        filterField.setContentHuggingPriority(.defaultLow, for: .horizontal)   // the field takes the slack

        content.addSubview(scroll)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
        ])
        w.contentView = content
        window = w
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in self?.render(force: false) }
        RunLoop.main.add(t, forMode: .common)   // .common so it keeps updating during menu tracking etc.
        timer = t
    }

    /// Rebuild the text from the current buffer + filter. While Auto-scroll is on this tails the newest
    /// lines; while it's off the view is frozen (so history can be read or selected) — except a `force`
    /// (open / filter change / Clear), which always re-renders so the control still responds.
    private func render(force: Bool) {
        let auto = autoScrollBox.state == .on
        guard force || auto else { return }
        let filter = filterField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let all = LogBuffer.snapshot()
        // Skip the rebuild when nothing changed — otherwise a live tail would clobber the user's selection
        // every tick.
        if !force, all.count == lastRenderedCount, filter == lastFilter { return }
        lastRenderedCount = all.count; lastFilter = filter
        let shown = logLinesFiltered(all, filter: filter)
        textView.string = shown.joined(separator: "\n")
        if auto { textView.scrollToEndOfDocument(nil) }
    }

    @objc private func filterChanged() { render(force: true) }
    @objc private func copyShown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }
    @objc private func clearLog() { LogBuffer.clear(); render(force: true) }

    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }
}
