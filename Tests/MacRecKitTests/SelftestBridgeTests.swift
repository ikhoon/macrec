import XCTest
@testable import MacRecKit

/// Runs the SAME `<module>Selftests(_ check:)` closure functions the `macrec selftest` subcommand runs,
/// but as an XCTest case: one failing check becomes one XCTest failure, named by the check's own label.
/// This is a second front-end over the existing assertions — not a reimplementation — so `swift test`
/// and `macrec selftest` can never diverge.
final class SelftestBridgeTests: XCTestCase {
    /// Every `<module>Selftests` function, in the same order Runner.swift runs them.
    private let suites: [(String, (_ check: (String, Bool) -> Void) -> Void)] = [
        ("locale", localeSelftests),
        ("audio", audioSelftests),
        ("transcriber", transcriberSelftests),
        ("translation", translationSelftests),
        ("settings", settingsSelftests),
        ("pipeline", pipelineSelftests),
        ("eval", evalSelftests),
    ]

    override func setUp() {
        super.setUp()
        // The selftests build the real Settings panes / overlay, which read credentials and write prefs.
        // Give them the same isolation the subcommand does: no Keychain, a throwaway defaults suite.
        Keychain.disabled = true
        Pref.useEphemeralStoreForTest()
    }

    /// One pass over every suite: assert each check AND accumulate the total. Kept as a SINGLE test so
    /// the suites (some write real WAVs / shell out to afconvert) run once per process, not once per
    /// method — and there's no `/tmp/macrec-selftest-<pid>` race if tests ever run in parallel.
    func testSelftestsPassAndMeetTheCheckFloor() {
        var total = 0
        for (label, fn) in suites {
            var perSuite = 0
            fn { name, ok in
                perSuite += 1
                total += 1
                XCTAssertTrue(ok, "[\(label)] \(name)")
            }
            XCTAssertGreaterThan(perSuite, 0, "[\(label)] ran no checks — suite not wired in?")
        }
        // Floor guard: catches a whole suite (or a big chunk of checks) silently dropping out. Pinned
        // well below the real count (~203) so ordinary net-negative churn doesn't trip a reflexive bump.
        XCTAssertGreaterThanOrEqual(total, 180, "selftest check count fell below the pinned floor (\(total))")
    }
}
