// make-icon.swift — draws a colorful app icon (gradient squircle + white waveform.badge.mic)
// and writes the .iconset PNGs. Usage: swift make-icon.swift <out.iconset-dir>
import AppKit

func drawIcon(_ px: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let full = NSRect(x: 0, y: 0, width: px, height: px)
    let inset = px * 0.085
    let body = full.insetBy(dx: inset, dy: inset)
    let corner = body.width * 0.2237                 // macOS-style rounded square
    let path = NSBezierPath(roundedRect: body, xRadius: corner, yRadius: corner)

    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.49, green: 0.17, blue: 0.96, alpha: 1),   // violet
        NSColor(srgbRed: 0.14, green: 0.52, blue: 1.00, alpha: 1),   // blue
    ])!
    grad.draw(in: body, angle: -55)
    NSGraphicsContext.current?.restoreGraphicsState()

    // white waveform-with-mic glyph, centered
    let cfg = NSImage.SymbolConfiguration(pointSize: px * 0.46, weight: .semibold)
    if let sym = NSImage(systemSymbolName: "waveform.badge.mic", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let g = sym.size
        let white = NSImage(size: g)
        white.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: g).fill()
        sym.draw(at: .zero, from: NSRect(origin: .zero, size: g), operation: .destinationIn, fraction: 1)
        white.unlockFocus()
        white.draw(in: NSRect(x: (px - g.width)/2, y: (px - g.height)/2, width: g.width, height: g.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let specs: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]
for (name, px) in specs {
    let rep = drawIcon(CGFloat(px))
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(name).png"))
}
print("wrote \(specs.count) PNGs to \(outDir)")
