import AppKit

// MARK: - windowed-app lifecycle decisions (pure, selftested)

/// A reflexive ⌘Q from any window must never kill 24/7 recording — only the tray Quit and
/// system-initiated stops (SIGTERM / a logout-reasoned quit event) really terminate. Pure.
func terminateShouldJustCloseWindow(realQuit: Bool, windowVisible: Bool) -> Bool {
    !realQuit && windowVisible
}
