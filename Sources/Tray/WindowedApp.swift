import AppKit

// MARK: - windowed-app lifecycle decisions (pure, selftested)

/// The activation policy for the moment: a REGULAR app (Dock icon, ⌘Tab) while the windowed surface
/// is up, a menu-bar accessory otherwise — the recorder boots headless and stays headless until the
/// user opens the Library. Pure.
func windowedActivationPolicy(libraryVisible: Bool) -> NSApplication.ActivationPolicy {
    libraryVisible ? .regular : .accessory
}

/// Should a terminate request merely CLOSE the front window instead of quitting? A reflexive ⌘Q
/// from ANY of the app's windows (Library, Status, Settings, Log) must never kill 24/7 recording —
/// only the tray's deliberate Quit (which arms the watchdog's stay-dead flag) and system-initiated
/// stops (SIGTERM / a logout-reasoned quit event, which must never be cancelled) terminate. Pure.
func terminateShouldJustCloseWindow(realQuit: Bool, windowVisible: Bool) -> Bool {
    !realQuit && windowVisible
}
