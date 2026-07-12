import AppKit
import AVFoundation
import EventKit
import Foundation

/// An NSView with a top-left origin (isFlipped) so settings content lays out top-down in a scroll view.
final class FlippedDocView: NSView { override var isFlipped: Bool { true } }

/// A rounded, hairline-bordered settings group. Marker type so the UI selftest can count
/// "every pane renders at least one section card".
final class SectionCard: NSView {}

/// A wrapping label that wraps to its ACTUAL laid-out width instead of a fixed guess — so a one-line
/// description stays one line when the window is wide and only wraps when it truly runs out of room
/// (user: the "Capture system audio" note wrapped needlessly). Give it leading+trailing and it sizes
/// its own height correctly at any window width.
final class WrappingLabel: NSTextField {
    override func layout() {
        super.layout()
        if abs(preferredMaxLayoutWidth - bounds.width) > 0.5 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// A secondary wrapping caption (row descriptions, section notes) that self-sizes to its width.
func wrappingCaption(_ s: String, size: CGFloat = 11, color: NSColor = .secondaryLabelColor) -> WrappingLabel {
    let l = WrappingLabel(labelWithString: s)
    l.font = .systemFont(ofSize: size)
    l.textColor = color
    l.lineBreakMode = .byWordWrapping
    l.maximumNumberOfLines = 0
    l.cell?.wraps = true
    l.cell?.isScrollable = false
    l.translatesAutoresizingMaskIntoConstraints = false
    l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return l
}

/// Should a nested scroll view hand the wheel event to its parent instead of eating it? Yes when its
/// own content already fits (nothing to scroll), so hovering the pointer over an embedded editor no
/// longer traps the gesture and the whole pane can still scroll. Pure + unit-tested.
func nestedScrollPassesThrough(contentHeight: CGFloat, clipHeight: CGFloat) -> Bool {
    contentHeight <= clipHeight + 0.5
}

/// A scroll view that forwards vertical wheel events UP to the enclosing pane scroller when its own
/// content fits (so a prompt/calendar box with the pointer over it doesn't block scrolling the pane —
/// the pointer over a prompt box used to trap the gesture). When its content genuinely overflows it keeps the
/// event and scrolls itself.
final class PassthroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let contentH = documentView?.bounds.height ?? 0
        if nestedScrollPassesThrough(contentHeight: contentH, clipHeight: contentView.bounds.height) {
            nextResponder?.scrollWheel(with: event)   // let the pane scroll
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Sidebar row: a monochrome SF Symbol + label. The icon follows the row's background style —
/// muted (secondary) normally, white when the row is selected (the accent-filled state) — so the
/// nav reads as one clean column, not a wall of colored tiles (user + design-review feedback).
final class SidebarCell: NSTableCellView {
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { imageView?.contentTintColor = backgroundStyle == .emphasized ? .white : .secondaryLabelColor }
    }
}

/// Sidebar selection is app state, not focus state: it must look identical whether or not the table is
/// first responder. AppKit's own drawing consults focus, so we draw the pill ourselves.
final class SidebarRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

/// Map a key-equivalent to the standard edit-action selector. Pure + unit-tested — ⌘V → `paste:`,
/// ⌘C → `copy:`, ⌘X → `cut:`, ⌘A → `selectAll:`, ⌘Z → `undo:`, ⌘⇧Z → `redo:`; nil for anything else
/// (the window then falls through to `super`). Requires the modifiers to match EXACTLY so ⌘⌥V etc.
/// aren't hijacked.
func standardEditSelector(key: String?, flags: NSEvent.ModifierFlags) -> Selector? {
    let k = key?.lowercased()
    if flags == .command {
        switch k {
        case "x": return #selector(NSText.cut(_:))
        case "c": return #selector(NSText.copy(_:))
        case "v": return #selector(NSText.paste(_:))
        case "a": return #selector(NSResponder.selectAll(_:))
        case "z": return Selector(("undo:"))
        default:  return nil
        }
    }
    if flags == [.command, .shift], k == "z" { return Selector(("redo:")) }
    return nil
}

/// A window that routes the standard edit shortcuts to the responder chain. An LSUIElement app has
/// no menu bar, so ⌘X/⌘C/⌘V/⌘A/⌘Z never reach a focused text field's field editor — pasting into
/// the Settings fields silently did nothing (user report). Dispatching the standard action selectors
/// via `sendAction(to: nil)` lands them on the field editor, which implements them.
final class EditableWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let sel = standardEditSelector(key: event.charactersIgnoringModifiers, flags: flags),
           NSApp.sendAction(sel, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Caption overlay panel: key-able despite `.nonactivatingPanel` (text selection needs key status),
/// and — since an LSUIElement app has no Edit menu to route key equivalents — ⌘C/⌘A are handled here.
final class CaptionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let tv = firstResponder as? NSTextView {
            switch event.charactersIgnoringModifiers {
            case "c": tv.copy(nil); return true
            case "a": tv.selectAll(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
