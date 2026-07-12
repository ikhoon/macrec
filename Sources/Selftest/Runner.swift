import AppKit
import AVFoundation
import EventKit
import Foundation

/// Runs every check, prints a line per check, and exits: 0 when all pass, 1 otherwise.
/// The checks themselves live in per-domain files (localeSelftests, audioSelftests, …), each a
/// `func …(_ check:)` called here in order — so the printed output is unchanged by the split.
func runSelftest() -> Never {
    var fails = 0
    func check(_ name: String, _ ok: Bool) { print("\(ok ? "ok  " : "FAIL") \(name)"); if !ok { fails += 1 } }
    localeSelftests(check)
    audioSelftests(check)
    transcriberSelftests(check)
    translationSelftests(check)
    settingsSelftests(check)
    pipelineSelftests(check)
    print(fails == 0 ? "selftest: ALL PASS" : "selftest: \(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
}
