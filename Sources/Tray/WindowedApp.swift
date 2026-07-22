import AppKit

// MARK: - windowed-app lifecycle decisions (pure, selftested)

/// A reflexive ⌘Q from any window must never kill 24/7 recording — only the tray Quit and
/// system-initiated stops (SIGTERM / a logout-reasoned quit event) really terminate. Pure.
func terminateShouldJustCloseWindow(realQuit: Bool, windowVisible: Bool) -> Bool {
    !realQuit && windowVisible
}

/// The NSAppearance name for a saved mode — nil means follow the system. Pure.
func appearanceName(for mode: String) -> NSAppearance.Name? {
    switch mode {
    case "light": return .aqua
    case "dark": return .darkAqua
    default: return nil
    }
}

/// Apply the saved appearance override app-wide (launch + Save).
func applySavedAppearance(d: UserDefaults = Pref.d) {
    NSApp.appearance = appearanceName(for: d.string(forKey: Pref.appearanceMode) ?? "system")
        .map { NSAppearance(named: $0) } ?? nil
}
