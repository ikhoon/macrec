import AppKit
import AVFoundation
import Foundation
import UserNotifications

/// Container for a custom NSMenuItem view that replicates the NATIVE hover behavior a plain view
/// lacks: the selection-material pill behind the row and an inverted (white) label while hovered.
/// AppKit draws that for ordinary items only — a `view`-backed item gets nothing. The view-backed
/// row exists so clicking "Transcribe now" does NOT dismiss the menu (user pick — watch the row's
/// spinner in place). Tracking uses .activeAlways because menu tracking runs in its own event mode.
final class MenuHoverView: NSView {
    private let highlight = NSVisualEffectView()
    var onHover: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]              // stretch with whatever width the menu settles on
        highlight.material = .selection
        highlight.state = .active
        highlight.isEmphasized = true
        highlight.blendingMode = .behindWindow
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 4
        highlight.layer?.cornerCurve = .continuous
        highlight.isHidden = true
        highlight.frame = bounds.insetBy(dx: 5, dy: 0)   // native menus inset the pill ~5 pt
        highlight.autoresizingMask = [.width, .height]
        addSubview(highlight, positioned: .below, relativeTo: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setHover(false)   // a menu reopen must never resurrect last time's highlight
    }

    func setHover(_ inside: Bool) {
        highlight.isHidden = !inside
        onHover?(inside)
    }

    var highlightVisibleForTest: Bool { !highlight.isHidden }
    var trackingReadyForTest: Bool { updateTrackingAreas(); return !trackingAreas.isEmpty }
}
