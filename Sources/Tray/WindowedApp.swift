import AppKit

// MARK: - windowed-app lifecycle decisions (pure, selftested)

/// The activation policy for the moment: a REGULAR app (Dock icon, ⌘Tab) while the windowed surface
/// is up, a menu-bar accessory otherwise — the recorder boots headless and stays headless until the
/// user opens the Library. Pure.
func windowedActivationPolicy(libraryVisible: Bool) -> NSApplication.ActivationPolicy {
    libraryVisible ? .regular : .accessory
}

/// Should a terminate request merely CLOSE the windowed surface instead of quitting? A windowed-app
/// user's reflexive ⌘Q must never kill 24/7 recording — only the tray's deliberate Quit (which sets
/// the watchdog flag) and system-initiated stops (SIGTERM/logout/shutdown, which must never be
/// cancelled) actually terminate. Pure.
func terminateShouldJustCloseWindow(realQuit: Bool, libraryVisible: Bool) -> Bool {
    !realQuit && libraryVisible
}
