import AppKit
import AVFoundation
import Foundation
import UserNotifications

/// "WE stopped the engine" — the user paused (`paused`) OR the schedule parked it off-hours
/// (`schedulePaused`). Clicking Resume in either state resumes/overrides and records now. This is the
/// ONE decision behind the tray toggle: its label, its enablement, and what a click does all route
/// through here, so they can't disagree (the schedule-paused Resume no-op was two of them
/// disagreeing — the click branch resumed only `if paused`). Pure + selftested.
func togglePauseShouldResume(paused: Bool, schedulePaused: Bool) -> Bool { paused || schedulePaused }

/// Whether the tray's Pause/Resume item should be clickable: enabled while stopped-by-us (so Resume
/// works, incl. off-hours) or while an engine is recording (so Pause works). Only true idle greys it
/// out. Pure.
func pauseItemEnabled(paused: Bool, schedulePaused: Bool, hasEngine: Bool) -> Bool {
    togglePauseShouldResume(paused: paused, schedulePaused: schedulePaused) || hasEngine
}

/// The two CAPTURE grants that gate recording are satisfied (System Audio + Microphone). Neutral
/// predicate shared by `allPermissionsGranted()` and the "Grant permissions…" hide logic — Calendar is
/// optional (titling) and deliberately excluded so a user who declined it isn't nagged. Pure + selftested.
func captureGrantsSatisfied(audioGranted: Bool, micGranted: Bool) -> Bool { audioGranted && micGranted }

/// A directory picker on a menu-bar (`.accessory`) app must present as a SHEET on a VISIBLE window,
/// or a bare `runModal()` opens behind everything (the "Choose… did nothing" bug). Fall back to
/// activate-then-runModal only when there's no visible window to host a sheet. Pure + selftested.
enum DirPickerPresentation: Equatable { case sheet, activateAndRunModal }
func dirPickerPresentation(hasVisibleWindow: Bool) -> DirPickerPresentation {
    hasVisibleWindow ? .sheet : .activateAndRunModal
}

/// The clickable URL for the "update available" alert, or nil for no button. Homebrew installs get no
/// button (they upgrade via `brew`). Otherwise the release URL — but ONLY if it is https (never let a
/// surprise API payload open a `file:` / `javascript:` / custom-scheme URL), falling back to the
/// hardcoded https releases page when the API url is missing/blank/unsafe. Pure + selftested.
func updateAlertOpenURL(installedViaBrew: Bool, htmlURL: String?, releasesURL: String) -> URL? {
    guard !installedViaBrew else { return nil }
    for s in [htmlURL, releasesURL] {
        if let s, let u = URL(string: s), u.scheme?.lowercased() == "https" { return u }
    }
    return nil
}
