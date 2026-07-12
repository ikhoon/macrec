import AppKit
import AVFoundation
import Foundation
import UserNotifications

/// A small rounded-tile vendor badge (solid brand color + white SF Symbol) for Settings section headers
/// and picker items — at-a-glance identity for each engine/runner. NOT a trademarked logo: a
/// self-contained, self-signed app can't embed those, so this is a tasteful brand-colored mark instead.
func vendorBadge(_ symbol: String, _ color: NSColor, side: CGFloat = 18) -> NSImage {
    let glyphCfg = NSImage.SymbolConfiguration(pointSize: side * 0.56, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(glyphCfg)
    let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        let body = rect.insetBy(dx: 0.5, dy: 0.5)
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(roundedRect: body, xRadius: body.width * 0.28, yRadius: body.width * 0.28).addClip()
        color.setFill(); body.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        if let glyph {
            let g = glyph.size
            glyph.draw(in: NSRect(x: (side - g.width)/2, y: (side - g.height)/2, width: g.width, height: g.height))
        }
        return true
    }
    img.isTemplate = false
    return img
}

/// macrec's menu-bar mark: the waveform-with-mic glyph (the old "transcribe" tray icon the user likes)
/// as a menu-bar TEMPLATE so it adapts to the light/dark menu bar — no colored tile (user: drop the blue
/// background). Voice tints it light orange; paused/idle dims the same mark (maccal-style) so it reads
/// inactive. Rendered at the glyph's NATURAL aspect (waveform-mic is wider than tall — a square box clipped it).
func brandMarkImage(side: CGFloat, recording: Bool, voice: Bool) -> NSImage {
    let lightOrange = NSColor.systemOrange.blended(withFraction: 0.35, of: .white) ?? .systemOrange
    let glyphCfg = NSImage.SymbolConfiguration(pointSize: side * 0.78, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [voice ? lightOrange : .white]))
    let glyph = NSImage(systemSymbolName: "waveform.badge.mic", accessibilityDescription: "macrec")?
        .withSymbolConfiguration(glyphCfg)
    let sz = glyph?.size ?? NSSize(width: side, height: side)   // natural aspect, not forced square
    let img = NSImage(size: sz, flipped: false) { rect in
        // paused/idle draws the same mark at 45% so it reads inactive (maccal-style). `fraction` is the
        // reliable opacity knob for NSImage.draw (cgContext.setAlpha didn't take).
        glyph?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: recording ? 1.0 : 0.45)
        return true
    }
    img.isTemplate = !voice   // template adapts to the light/dark menu bar; the voice tint keeps its color
    return img
}

/// Headless guard: the brand mark actually draws (not an all-transparent image — the "shipped visually
/// destroyed" class of bug). Renders to an offscreen bitmap and checks a meaningful fraction is opaque.
func brandMarkHasContent(recording: Bool, voice: Bool) -> Bool {
    let side: CGFloat = 18, scale = 4
    let px = Int(side) * scale
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
    rep.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    brandMarkImage(side: side, recording: recording, voice: voice).draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    var opaque = 0
    for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
        if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { opaque += 1 }
    }}
    return opaque > px * px / 10   // ≥ ~10% drawn
}
