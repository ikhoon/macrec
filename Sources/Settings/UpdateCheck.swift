import AppKit
import AVFoundation
import EventKit
import Foundation

// MARK: - update check (Sparkle-style UX, zero dependencies — GitHub Releases is the appcast)

/// Dotted-numeric version compare: "0.10.1" > "0.9.9" (string compare would say otherwise).
/// Missing components are zero; a leading "v" is tolerated. Pure + testable.
func isNewerVersion(_ candidate: String, than current: String) -> Bool {
    func parts(_ s: String) -> [Int] {
        s.trimmingCharacters(in: .whitespaces).lowercased()
            .split(separator: ".").map { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "v "))) ?? 0 }
    }
    let a = parts(candidate), b = parts(current)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

/// The title bar and footer a pane's document height doesn't account for.
let snapshotChromeHeight: CGFloat = 96

/// How tall to make the window when snapshotting a pane: enough to show the whole pane, never shorter
/// than the runtime size (a short pane must still look like the real window), and capped so a runaway
/// document can't produce a PNG nobody will open. Pure + selftested.
func snapshotContentHeight(runtime: CGFloat, document: CGFloat, cap: CGFloat = 4000) -> CGFloat {
    min(max(runtime, document), cap)
}
