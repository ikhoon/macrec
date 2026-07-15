import AppKit
import AVFoundation
import Foundation
import Speech
import Translation

func captionBackdropAlpha(_ pref: Double) -> CGFloat {
    CGFloat(min(captionOpacityRange.upperBound, max(captionOpacityRange.lowerBound, pref)))
}

/// What a subtitle actually shows. A film subtitle is not a transcript log: it is the last thing said,
/// centred, with the translation carrying the line and the original demoted to a whisper above it. When
/// there is no translation the original IS the subtitle. Pure + selftested.
func subtitleLine(original: String, translated: String?) -> (main: String, secondary: String?) {
    guard let t = translated?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
        return (original, nil)
    }
    return (t, original.isEmpty ? nil : original)
}

/// Subtitles are read at a glance from across the room: bigger than the log's body text, and never
/// smaller than legible. Pure + selftested.
func subtitleFontSize(_ base: CGFloat) -> CGFloat { max(18, base + 6) }

/// How many utterances a subtitle shows. Just the current one — a film subtitle is what's being said
/// right now, and past sentences (available in the log view) only clutter it. Pure + selftested.
let subtitleMaxLines = 1

/// The window outline exists so a transparent LOG still reads as a window you can grab. A subtitle is
/// not a window — a rectangle drawn around a film subtitle is exactly what breaks the illusion.
/// Pure + selftested.
func captionEdgeVisible(subtitle: Bool) -> Bool { !subtitle }

/// The newest line is what the reader is following, so past lines are dimmed to let the eye land on it.
/// The current line stays at full strength. Pure + selftested.
func captionLineAlpha(isCurrent: Bool) -> CGFloat { isCurrent ? 1.0 : 0.5 }

/// Do the captions have to carry their own contrast? Whenever the backdrop is anything but fully opaque:
/// the opacity slider must fade only the window background, never the text or the solid band behind it, so
/// the captions stay readable at every opacity. A plate over a fully-solid panel is the only redundant
/// case (a darker box on a dark box), so it is the only one skipped. Pure + selftested.
func captionTextNeedsBackplate(backdropAlpha: CGFloat) -> Bool { backdropAlpha < 1.0 }

/// Did the overlay render to nothing? An offscreen render of a window-server-composited surface returns
/// an empty bitmap, and a harness that writes that PNG "verifies" every bug there is. A real overlay has
/// a backdrop AND bright caption glyphs — checking only for "some pixels" would pass a caption-less slab.
func snapshotIsBlank(_ rep: NSBitmapImageRep, brightPixelsNeeded: Int = 40) -> Bool {
    var bright = 0
    for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if c.alphaComponent > 0.5 && c.brightnessComponent > 0.6 { bright += 1 }
            if bright >= brightPixelsNeeded { return false }
        }
    }
    return true
}

/// A view that is seen but never touched — it sits over the captions purely to draw the outline, so it
/// must not swallow clicks, text selection, or the window drag.
final class NonInteractiveView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Floating always-on-top panel showing the live captions. A compact control bar along the top holds
/// the live settings (language, who to transcribe, translation, text size, timestamps) so changes take
/// effect immediately; opacity is a drag slider on that bar. Nothing lives in the Settings window.
@available(macOS 26, *)
/// The floating caption overlay — a layer-backed HUD panel showing live transcription/translation.
final class LiveCaptionWindow: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    /// The only thing the opacity slider fades. Layer-backed, not an NSVisualEffectView: the window
    /// server composites a `.behindWindow` material and ignores the view's alpha.
    private let backdrop = NSView()
    /// A faint outline that does NOT fade with the backdrop, so a transparent log still reads as a window.
    private let edge = NonInteractiveView()
    private let textView = NSTextView()
    private let onClose: () -> Void
    private let onReconfigure: () -> Void   // language / source / translation changed → rebuild the engine
    private let onRestyle: () -> Void        // text size / timestamps changed → just re-render
    private var suppressCloseCallback = false
    private let langPopup = NSPopUpButton(), sourcePopup = NSPopUpButton(), translatePopup = NSPopUpButton()
    private let tsToggle = NSButton(checkboxWithTitle: "Time", target: nil, action: nil)
    private let subToggle = NSButton(checkboxWithTitle: "Subtitle", target: nil, action: nil)
    private var controlsAccessory: NSTitlebarAccessoryViewController?   // the full control strip (collapsible)
    private let collapseBtn = NSButton()                                // chevron RIGHT NEXT TO the title text
    private var chevronLead: NSLayoutConstraint?                        // titlebar.centerX + titleWidth/2 + gap
    private var engineChoices: [LiveEngine] = []                        // exactly what the engine popup lists
    private let enginePopup = NSPopUpButton()                           // rebuilt when Settings change
    private static let titleIcon = "🎙️"           // beautifies the "macrec live" title
    // The window server rounds a titled window's bottom corners; the radius isn't public. Measured at 15pt
    // on the overlay's target (macOS 26). The outline traces the same radius so a fully-transparent overlay
    // still reads as a rounded window instead of a bare rectangle.
    static let windowCornerRadius: CGFloat = 15

    @objc private func toggleControlBar() {
        setControlBar(collapsed: !(controlsAccessory?.isHidden ?? false))
    }
    private func setControlBar(collapsed: Bool, persist: Bool = true) {
        // The chevron lives in the TITLE ROW next to "macrec live" (user-requested spot; corners read
        // as window chrome, in-bar read as a caption setting). Collapsing just hides the whole strip —
        // its 32 pt comes back to the captions, and the chevron stays visible to expand again.
        controlsAccessory?.isHidden = collapsed
        let label = collapsed ? "Show caption controls" : "Hide caption controls"
        // The classic chevron pair, sized down a notch (user pick: compact/sheet-grabber read oddly here).
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        collapseBtn.image = NSImage(systemSymbolName: collapsed ? "chevron.down" : "chevron.up",
                                    accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        collapseBtn.setAccessibilityLabel(label)   // VoiceOver reads the BUTTON's label, not the image's
        collapseBtn.toolTip = label
        // Persist only on user toggles: writing during init would CREATE the defaults key on first
        // launch, and an existing key shadows the MR_LIVE_BAR_COLLAPSED env override forever after.
        if persist { Pref.d.set(collapsed, forKey: Pref.liveBarCollapsed) }
    }
    /// Set the window title AND keep the chevron glued to its right edge (the title is centered, so
    /// the offset is centerX + measured-title-width/2; re-measured on every title change).
    private func setTitle(_ s: String) {
        panel.title = s
        let font = NSFont.titleBarFont(ofSize: NSFont.smallSystemFontSize)   // utility-panel title size
        let w = (s as NSString).size(withAttributes: [.font: font]).width
        chevronLead?.constant = w / 2 + 8
    }

    init(onClose: @escaping () -> Void, onReconfigure: @escaping () -> Void, onRestyle: @escaping () -> Void) {
        self.onClose = onClose; self.onReconfigure = onReconfigure; self.onRestyle = onRestyle
        // NOT `.hudWindow`: that style inserts a full-window NSVisualEffectView as the theme frame's
        // bottom-most subview, under everything we own. It kept painting its dark material no matter
        // what the opacity slider did, so the overlay could never go fully transparent. We draw our own
        // dark fill (`backdrop`) instead and force the dark appearance so the titlebar still matches.
        panel = CaptionPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 172),   // default fits one more caption line
                             styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        super.init()
        panel.title = "\(Self.titleIcon) macrec live"
        // The window itself is ALWAYS fully opaque — see captionBackdropAlpha. Its content area draws
        // nothing (clear + non-opaque), so the only thing behind the captions is `backdrop`, whose
        // alpha the slider moves. Fading the window would fade the captions with it.
        panel.alphaValue = 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        // Text selection needs the panel to become key on a text click (nonactivating panels never do
        // by default → drag-select and ⌘C silently went to the previous app). "OnlyIfNeeded" keeps the
        // no-focus-steal behavior everywhere except selectable text.
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        // Controls live in the titlebar (a full-width accessory strip just below it) so they read as
        // window chrome, not content — the caption area stays clean. Each control applies immediately.
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .bottom
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 32))
        host.autoresizingMask = [.width]
        let bar = buildControlBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            host.heightAnchor.constraint(equalToConstant: 32),
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
            bar.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        accessory.view = host
        panel.addTitlebarAccessoryViewController(accessory)
        controlsAccessory = accessory

        // Collapse chevron in the TITLE ROW, glued to the right of "🎙️ macrec live · …". The titlebar
        // container is the close button's superview; the leading offset from center tracks the measured
        // title width (see setTitle). Sticky across sessions.
        collapseBtn.isBordered = false
        collapseBtn.bezelStyle = .regularSquare
        collapseBtn.imagePosition = .imageOnly
        collapseBtn.target = self
        collapseBtn.action = #selector(toggleControlBar)
        var chevronAttached = false
        if let closeBtn = panel.standardWindowButton(.closeButton), let titlebar = closeBtn.superview {
            collapseBtn.translatesAutoresizingMaskIntoConstraints = false
            titlebar.addSubview(collapseBtn)
            let lead = collapseBtn.leadingAnchor.constraint(equalTo: titlebar.centerXAnchor, constant: 60)
            chevronLead = lead
            // Y pins to the CLOSE BUTTON (which sits in the title row) — the titlebar container also
            // spans the bottom accessory strip, so its centerY would drop the chevron onto the controls.
            // The -1.5 pt trims the symbol's optical balance against the title text (fractional points
            // land on pixel boundaries on Retina; -2 sat visibly high after the glyph-size change).
            NSLayoutConstraint.activate([lead, collapseBtn.centerYAnchor.constraint(equalTo: closeBtn.centerYAnchor, constant: -1.5)])
            chevronAttached = true
        }
        setTitle(panel.title)   // measure the initial title → position the chevron
        // Never RESTORE a collapsed bar when the toggle couldn't be attached — there'd be no way back.
        let restoreCollapsed = chevronAttached && Pref.bool(Pref.liveBarCollapsed, "MR_LIVE_BAR_COLLAPSED", false)
        setControlBar(collapsed: restoreCollapsed, persist: false)

        // --- captions (scrollable text) fill the whole content (opacity moved up to the control bar) ---
        let content = panel.contentView!
        backdrop.frame = content.bounds
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        // The HUD panel's own dark fill, reproduced so we own its alpha. Pure black reads too heavy
        // against a bright screen at full opacity, so this matches the panel chrome's tone.
        backdrop.layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
        // Round the fill's bottom corners to the window radius so the dark card owns its own rounded shape
        // (matching the window's clip exactly) instead of relying on the window server — which keeps the
        // corners consistent at every opacity and lets the offscreen snapshot show the true shape.
        backdrop.layer?.cornerRadius = Self.windowCornerRadius
        backdrop.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        backdrop.alphaValue = captionBackdropAlpha(Pref.dbl(Pref.liveOpacity, "MR_LIVE_OPACITY", 0.5))
        content.addSubview(backdrop)
        let scroll = NSScrollView(frame: content.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = false     // the scrollbar reads as clutter on a caption overlay — hidden
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // Canonical scrollable NSTextView setup so vertical resizing + scrolling behave correctly.
        let size = scroll.contentSize
        textView.frame = NSRect(origin: .zero, size: size)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = false; textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        scroll.documentView = textView
        content.addSubview(scroll, positioned: .above, relativeTo: backdrop)

        // The outline goes on TOP so it isn't covered by the captions, and never fades with the
        // backdrop. It ignores the mouse (NonInteractiveView) so text selection and dragging still work.
        edge.frame = content.bounds
        edge.autoresizingMask = [.width, .height]
        edge.wantsLayer = true
        edge.layer?.borderWidth = 1
        edge.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        // Round the BOTTOM corners to the window's radius so the outline hugs the window's rounded corners —
        // the only thing that reads as a window when the backdrop is fully transparent. The top two meet the
        // square titlebar, so they stay sharp.
        edge.layer?.cornerRadius = Self.windowCornerRadius
        edge.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        content.addSubview(edge, positioned: .above, relativeTo: scroll)
    }

    /// Reads back what the opacity slider actually moved — the captions must never be the thing that fades.
    var captionAlphasForTest: (window: CGFloat, backdrop: CGFloat, text: CGFloat) {
        (panel.alphaValue, backdrop.alphaValue, textView.alphaValue)
    }
    func setOpacityForTest(_ v: Double) { applyOpacity(v) }

    /// Nothing may paint behind the backdrop that the opacity slider cannot reach.
    var nothingPaintsBehindBackdropForTest: Bool {
        guard let frame = panel.contentView?.superview else { return false }
        return !frame.subviews.contains { $0 is NSVisualEffectView }
    }

    /// Does the backdrop actually PAINT? Asserting its alpha alone was a false all-clear.
    var backdropPaintsForTest: Bool {
        guard let content = panel.contentView, backdrop.wantsLayer,
              let fill = backdrop.layer?.backgroundColor, fill.alpha == 1,
              let bi = content.subviews.firstIndex(of: backdrop),
              let ti = content.subviews.firstIndex(where: { $0 is NSScrollView }) else { return false }
        return bi < ti && backdrop.frame.size == content.bounds.size
    }

    /// The outline stays put and stays untouchable no matter where the opacity slider sits.
    var edgeSurvivesForTest: (visible: Bool, ignoresMouse: Bool) {
        let border = edge.layer.map { $0.borderWidth > 0 && ($0.borderColor?.alpha ?? 0) > 0 } ?? false
        return (border && edge.alphaValue == 1 && !edge.isHidden,
                edge.hitTest(NSPoint(x: 5, y: 5)) == nil)
    }

    /// BOTH corner layers must trace the window's rounded BOTTOM corners — the outline (visible when the
    /// backdrop is transparent) and the backdrop fill (visible when it isn't) — or a transparent overlay
    /// collapses to a bare rectangle. Wiring-level guard; the rendered shape itself is what
    /// `caption-snapshot` shows and the eyeball checks.
    var cornerRoundingForTest: (edgeRadius: CGFloat, edgeBottomOnly: Bool,
                                backdropRadius: CGFloat, backdropBottomOnly: Bool) {
        (edge.layer?.cornerRadius ?? 0,
         edge.layer?.maskedCorners == [.layerMinXMinYCorner, .layerMaxXMinYCorner],
         backdrop.layer?.cornerRadius ?? 0,
         backdrop.layer?.maskedCorners == [.layerMinXMinYCorner, .layerMaxXMinYCorner])
    }

    /// UI TEST KIT (`macrec caption-snapshot <dir>`): render the overlay at several opacities onto a
    /// checkerboard. The one thing to LOOK for: the background fades, the captions never do.
    ///
    /// This used to shell out to `screencapture`, because the backdrop was a `.behindWindow`
    /// NSVisualEffectView inside a `.hudWindow` — both composited by the window server, so an offscreen
    /// render returned a blank slab and would have "passed" whatever the slider did. Neither is here any
    /// more: the backdrop is a layer-backed fill the app draws itself, so `cacheDisplay` sees the truth
    /// and no Screen Recording permission is needed. `snapshotIsBlank` guards the old failure mode —
    /// a harness that cannot see the thing must fail, not write a reassuring PNG.
    func snapshotOpacities(_ values: [Double], to dir: URL) -> [URL] {
        var written: [URL] = []
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        renderSampleCaptions()
        show()
        panel.orderFrontRegardless()
        guard let content = panel.contentView else { return [] }
        for v in values {
            applyOpacity(v)
            content.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
            content.cacheDisplay(in: content.bounds, to: rep)
            guard !snapshotIsBlank(rep) else {
                elog("caption-snapshot: the overlay rendered to nothing at opacity \(v) — refusing to write a blank PNG")
                continue
            }
            // `rep.draw(in:)` composites with `.copy`: its transparent pixels overwrite the checkerboard
            // with black, and the overlay then looks opaque at every opacity. Go through NSImage so the
            // draw is `.sourceOver` and the backdrop's alpha actually shows the board through it.
            let layer = NSImage(size: content.bounds.size)
            layer.addRepresentation(rep)
            let shot = NSImage(size: content.bounds.size)
            shot.lockFocus()
            drawCheckerboard(in: content.bounds)   // transparency is only visible against something
            layer.draw(in: NSRect(origin: .zero, size: content.bounds.size),
                       from: .zero, operation: .sourceOver, fraction: 1)
            shot.unlockFocus()
            guard let tiff = shot.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
                  let png = bmp.representation(using: .png, properties: [:]) else { continue }
            let url = dir.appendingPathComponent(String(format: "overlay-opacity-%.2f.png", v))
            try? png.write(to: url)
            written.append(url)
        }
        panel.orderOut(nil)
        return written
    }

    /// The same offscreen render `caption-snapshot` writes, handed back for inspection.
    func renderContentForTest() -> NSBitmapImageRep? {
        guard let content = panel.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: rep)
        return rep
    }

    /// Two lines of Japanese with Korean translations — the ja→ko case this overlay exists for.
    func renderSampleCaptions() {
        render([(speaker: "me", text: "会議を始めましょう。", translated: "회의를 시작합시다.",
                 time: Date(timeIntervalSince1970: 0), mine: true, inProgress: false),
                (speaker: "them", text: "資料は共有済みです。", translated: "자료는 이미 공유했습니다.",
                 time: Date(timeIntervalSince1970: 4), mine: false, inProgress: true)],
               showTimestamps: true, fontSize: 14, showLabels: true)
    }

    /// A light/dark checker, in fixed sRGB. A dynamic system colour resolves against the current
    /// appearance, and `NSImage.lockFocus` has none — every tile came out the same pink. The pale tile is
    /// deliberately near-white: a caption that vanishes on a bright background is the failure to look for.
    private func drawCheckerboard(in rect: NSRect) {
        let light = NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1)
        let dark = NSColor(srgbRed: 0.42, green: 0.45, blue: 0.52, alpha: 1)
        let tile: CGFloat = 16
        var y: CGFloat = 0
        while y < rect.height {
            var x: CGFloat = 0
            while x < rect.width {
                ((Int(x / tile) + Int(y / tile)) % 2 == 0 ? light : dark).setFill()
                NSRect(x: x, y: y, width: tile, height: tile).fill()
                x += tile
            }
            y += tile
        }
    }

    /// Build the top control bar. Each control writes its Pref and fires the matching callback so the
    /// change is live: engine rebuild for language/source/translation, re-render for text size/timestamps.
    private func buildControlBar() -> NSStackView {
        func fill(_ p: NSPopUpButton, _ titles: [String], _ sel: Int, _ tip: String, _ action: Selector) {
            p.addItems(withTitles: titles); p.selectItem(at: sel)
            p.controlSize = .small; p.font = .systemFont(ofSize: 11); p.toolTip = tip
            p.target = self; p.action = action
            p.setContentHuggingPriority(.required, for: .horizontal)
        }
        let O = LiveCaptionOptions.self
        fill(langPopup, O.langTitles, idx(Pref.d.string(forKey: Pref.captionLang) ?? "", O.langValues),
             "Caption language", #selector(langChanged(_:)))
        fill(sourcePopup, O.sourceTitles, idx(LiveSource.current.rawValue, O.sourceValues),
             "Who to transcribe (fewer = faster)", #selector(sourceChanged(_:)))
        fill(translatePopup, O.transTitles, idx(Pref.d.string(forKey: Pref.translateTo) ?? "", O.transValues),
             "Translate captions to…", #selector(translateChanged(_:)))
        let aMinus = NSButton(title: "A－", target: self, action: #selector(fontSmaller))
        let aPlus  = NSButton(title: "A＋", target: self, action: #selector(fontBigger))
        for b in [aMinus, aPlus] { b.controlSize = .small; b.bezelStyle = .roundRect; b.font = .systemFont(ofSize: 11) }
        aMinus.toolTip = "Smaller text"; aPlus.toolTip = "Bigger text"
        tsToggle.controlSize = .small; tsToggle.font = .systemFont(ofSize: 11); tsToggle.toolTip = "Show timestamps"
        tsToggle.state = Pref.bool(Pref.liveTimestamps, "MR_LIVE_TIMESTAMPS", true) ? .on : .off
        tsToggle.target = self; tsToggle.action = #selector(tsToggled(_:))
        subToggle.controlSize = .small; subToggle.font = .systemFont(ofSize: 11)
        subToggle.toolTip = "Subtitle view — the last line, centred, translation first"
        subToggle.state = Pref.bool(Pref.liveSubtitle, "MR_LIVE_SUBTITLE", false) ? .on : .off
        subToggle.target = self; subToggle.action = #selector(subtitleToggled(_:))
        tsToggle.isEnabled = subToggle.state == .off
        // Engine select box — only engines that are switched on AND have what they need to run.
        engineChoices = selectableLiveEngines(LiveEngine.allCases, ready: { $0.isReady }, enabled: { $0.isEnabled })
        fill(enginePopup, engineChoices.map { $0.title }, engineChoices.firstIndex(of: .current) ?? 0,
             "Engine — Apple: fast · Whisper: accurate. Add a key in Settings to unlock the cloud engines.",
             #selector(engineChanged(_:)))
        // Opacity drag slider, now on the top bar (was a bottom strip).
        let opacity = NSSlider(value: Double(captionBackdropAlpha(Pref.dbl(Pref.liveOpacity, "MR_LIVE_OPACITY", 0.5))),
                               minValue: captionOpacityRange.lowerBound, maxValue: captionOpacityRange.upperBound,
                               target: self, action: #selector(opacityChanged(_:)))
        opacity.controlSize = .mini; opacity.toolTip = "Background opacity (captions stay readable)"
        opacity.translatesAutoresizingMaskIntoConstraints = false
        opacity.widthAnchor.constraint(equalToConstant: 72).isActive = true
        // A small leading icon per select box says what it controls, without text-label clutter.
        func icon(_ name: String, _ tip: String) -> NSImageView {
            let iv = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: tip) ?? NSImage())
            iv.symbolConfiguration = .init(pointSize: 12, weight: .regular)
            iv.contentTintColor = .secondaryLabelColor; iv.toolTip = tip
            iv.setContentHuggingPriority(.required, for: .horizontal); return iv
        }
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let copyBtn = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!,
                               target: self, action: #selector(copyTranscript))
        copyBtn.isBordered = false; copyBtn.imagePosition = .imageOnly
        copyBtn.toolTip = "Copy the transcript (selection, or everything)"
        copyBtn.setAccessibilityLabel("Copy transcript")
        copyBtn.setContentHuggingPriority(.required, for: .horizontal)
        let bar = NSStackView(views: [
            icon("cpu", "Engine"), enginePopup,
            icon("globe", "Caption language"), langPopup,
            icon("person.2", "Who to transcribe"), sourcePopup,
            icon("character.bubble", "Translate to"), translatePopup,
            spacer, copyBtn, aMinus, aPlus, subToggle, tsToggle, opacity])
        bar.orientation = .horizontal; bar.alignment = .centerY; bar.spacing = 5; bar.distribution = .fill
        return bar
    }

    private func idx<T: Equatable>(_ v: T, _ arr: [T]) -> Int { arr.firstIndex(of: v) ?? 0 }

    @objc private func langChanged(_ s: NSPopUpButton) {
        Pref.d.set(LiveCaptionOptions.langValues[max(0, s.indexOfSelectedItem)], forKey: Pref.captionLang); onReconfigure()
    }
    @objc private func sourceChanged(_ s: NSPopUpButton) {
        Pref.d.set(LiveCaptionOptions.sourceValues[max(0, s.indexOfSelectedItem)], forKey: Pref.liveSource); onReconfigure()
    }
    @objc private func translateChanged(_ s: NSPopUpButton) {
        Pref.d.set(LiveCaptionOptions.transValues[max(0, s.indexOfSelectedItem)], forKey: Pref.translateTo); onReconfigure()
    }
    @objc private func fontSmaller() { adjustFont(-2) }
    @objc private func fontBigger()  { adjustFont(+2) }
    private func adjustFont(_ delta: CGFloat) {
        let next = min(28, max(11, CGFloat(Pref.dbl(Pref.liveFontSize, "MR_LIVE_FONT_SIZE", 14)) + delta))
        Pref.d.set(Double(next), forKey: Pref.liveFontSize); onRestyle()
    }
    @objc private func tsToggled(_ s: NSButton) { Pref.d.set(s.state == .on, forKey: Pref.liveTimestamps); onRestyle() }
    @objc private func subtitleToggled(_ s: NSButton) {
        Pref.d.set(s.state == .on, forKey: Pref.liveSubtitle)
        tsToggle.isEnabled = s.state == .off   // a subtitle has no timestamps; don't offer a dead switch
        onRestyle()
    }
    /// Copy the current selection — or the whole transcript when nothing is selected.
    @objc private func copyTranscript() {
        let sel = textView.selectedRange()
        let text = (sel.length > 0 ? (textView.string as NSString).substring(with: sel) : textView.string)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    /// Settings changed while the overlay is open: an engine switched off (or a key just added) has to
    /// show up in the picker NOW — it was built once, at window creation, and never revisited.
    func reloadEngineChoices() {
        engineChoices = selectableLiveEngines(LiveEngine.allCases, ready: { $0.isReady }, enabled: { $0.isEnabled })
        enginePopup.removeAllItems()
        enginePopup.addItems(withTitles: engineChoices.map { $0.title })
        enginePopup.selectItem(at: engineChoices.firstIndex(of: .current) ?? 0)
    }
    var engineChoicesForTest: [LiveEngine] { engineChoices }

    @objc private func engineChanged(_ s: NSPopUpButton) {
        guard let e = engineAtPopupIndex(s.indexOfSelectedItem, choices: engineChoices) else { return }
        Pref.d.set(e.rawValue, forKey: Pref.liveEngine); onReconfigure()
    }

    @objc private func opacityChanged(_ s: NSSlider) { applyOpacity(s.doubleValue) }

    private func applyOpacity(_ v: Double) {
        backdrop.alphaValue = captionBackdropAlpha(v)   // background only — captions stay fully opaque
        Pref.d.set(v, forKey: Pref.liveOpacity)
        onRestyle()   // the captions' outline depends on the backdrop — re-render at the new opacity
    }

    func show() {
        if let f = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.maxX - panel.frame.width - 24, y: f.minY + 24))
        }
        panel.orderFrontRegardless()
    }
    func close() { suppressCloseCallback = true; panel.close() }

    /// Show the active transcription language in the title bar (human name, e.g. "🎙️ macrec live · Korean").
    func setLanguage(_ name: String) { setTitle("\(Self.titleIcon) macrec live · \(name)") }
    /// Shown while the analyzer warms up (model/ANE load) — the overlay is otherwise blank for ~10s.
    func setPreparing() { setTitle("\(Self.titleIcon) macrec live · starting…") }

    private let tsFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// Render for glanceable reading. With both speakers each gets a distinct tint (teal = you, orange =
    /// them) on a bold label; a single speaker drops the label and uses the primary color. All text starts
    /// at one shared column via a tab stop, and wrapped lines hang-indent to that same column — so line 2+
    /// aligns flush under the text regardless of the timestamp/label prefix width.
    /// Film-subtitle presentation: the last utterance, centred, translation leading and the original
    /// demoted above it. Contrast lives BEHIND the glyphs (a plate) — never in them: a blurred halo
    /// smears the strokes and a `strokeWidth` outline reads as a heavier font weight.
    private func renderSubtitle(_ lines: [(speaker: String, text: String, translated: String?, time: Date, mine: Bool, inProgress: Bool)],
                                fontSize: CGFloat) {
        let size = subtitleFontSize(fontSize)
        let mainFont = NSFont.systemFont(ofSize: size, weight: .semibold)
        // The original is a reference line above the translation, not a footnote — keep the size gap small
        // (a hair smaller, not half the size) so both read comfortably.
        let subFont = NSFont.systemFont(ofSize: max(15, size - 3), weight: .regular)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineHeightMultiple = 1.15
        para.paragraphSpacing = 6
        // Contrast goes behind the glyphs, never into them — a `strokeWidth` outline reads as a heavier
        // font weight. A shadow alone is not enough: against a bright window the captions all but vanish
        // (seen in `caption-snapshot`). Centred text makes a `.backgroundColor` run hug the line, which is
        // the black band broadcast subtitles use — and it only appears when the backdrop can't do the job.
        // Single source of truth: the slider already wrote the live value into backdrop.alphaValue —
        // re-deriving from prefs here duplicated the lookup (and its default) in two places.
        let plate = captionTextNeedsBackplate(backdropAlpha: backdrop.alphaValue)
            ? NSColor.black.withAlphaComponent(0.8) : NSColor.clear
        let halo = NSShadow()
        halo.shadowColor = NSColor.black.withAlphaComponent(0.85)
        halo.shadowBlurRadius = 2
        halo.shadowOffset = NSSize(width: 0, height: -1)

        let out = NSMutableAttributedString()
        for (i, l) in lines.suffix(subtitleMaxLines).enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            let (main, secondary) = subtitleLine(original: l.text, translated: l.translated)
            // Color by WHAT the text is, never by its slot: the original stays white and the translation
            // stays teal. Coloring the main line always-teal made a fresh sentence (shown as main before its
            // translation lands) flash teal, then flip to white the instant the translation arrived and the
            // original demoted to the secondary line. The main line is the translation only when one exists.
            let mainIsTranslation = !(l.translated?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if let secondary {
                out.append(NSAttributedString(string: secondary + "\n", attributes: [
                    .font: subFont, .foregroundColor: NSColor.white,
                    .backgroundColor: plate, .shadow: halo, .paragraphStyle: para]))
            }
            out.append(NSAttributedString(string: main, attributes: [
                .font: mainFont, .foregroundColor: mainIsTranslation ? NSColor.systemTeal : NSColor.white,
                .backgroundColor: plate, .shadow: halo, .paragraphStyle: para]))
        }
        textView.textStorage?.setAttributedString(out)
        textView.scrollToEndOfDocument(nil)
    }

    func render(_ lines: [(speaker: String, text: String, translated: String?, time: Date, mine: Bool, inProgress: Bool)],
                showTimestamps: Bool, fontSize: CGFloat, showLabels: Bool) {
        let tsFont = NSFont.monospacedDigitSystemFont(ofSize: max(9, fontSize - 3), weight: .regular)
        let labelFont = NSFont.boldSystemFont(ofSize: fontSize)
        let textFont = NSFont.systemFont(ofSize: fontSize)
        let transFont = NSFont.systemFont(ofSize: fontSize)   // same size as the caption — translation is the point
        func w(_ s: String, _ f: NSFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: f]).width }
        // Shared text column = timestamp width (constant, monospaced) + widest speaker label + a gap.
        let tsW = showTimestamps ? w("00:00:00  ", tsFont) : 0
        let labelW = showLabels ? (lines.map { w("\($0.speaker)  ", labelFont) }.max() ?? 0) : 0
        // A subtitle is not the log with its chrome off: timestamps and labels go regardless of toggles.
        let subtitleMode = Pref.bool(Pref.liveSubtitle, "MR_LIVE_SUBTITLE", false)
        edge.isHidden = !captionEdgeVisible(subtitle: subtitleMode)
        if subtitleMode {
            renderSubtitle(lines, fontSize: fontSize)
            return
        }
        let hasPrefix = showTimestamps || showLabels
        let col = hasPrefix ? tsW + labelW + 8 : 0
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = 0; para.headIndent = col
        para.lineHeightMultiple = 1.1; para.paragraphSpacing = 4
        if hasPrefix { para.tabStops = [NSTextTab(textAlignment: .left, location: col)]; para.defaultTabInterval = col }
        let markFont = NSFont.systemFont(ofSize: max(9, fontSize - 4))   // the arrow is a footnote, not a headline
        let trans = NSMutableParagraphStyle()
        trans.firstLineHeadIndent = col; trans.headIndent = col + w("↳ ", markFont); trans.lineHeightMultiple = 1.1
        let out = NSMutableAttributedString()
        for (i, l) in lines.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            let tint: NSColor = l.mine ? .systemTeal : .systemOrange   // colors the LABEL only (both-speaker mode)
            // Dim every line but the newest so the eye lands on what's being said now.
            let cur = i == lines.count - 1
            func fg(_ c: NSColor) -> NSColor { cur ? c : c.withAlphaComponent(captionLineAlpha(isCurrent: cur)) }
            if showTimestamps {
                out.append(NSAttributedString(string: "\(tsFormatter.string(from: l.time))  ", attributes: [
                    .font: tsFont, .foregroundColor: fg(.secondaryLabelColor), .paragraphStyle: para]))
            }
            if showLabels {
                out.append(NSAttributedString(string: "\(l.speaker)  ", attributes: [
                    .font: labelFont, .foregroundColor: fg(tint), .paragraphStyle: para]))
            }
            if hasPrefix { out.append(NSAttributedString(string: "\t", attributes: [.font: textFont, .paragraphStyle: para])) }
            out.append(NSAttributedString(string: l.text, attributes: [   // text stays neutral like single-speaker mode
                .font: textFont, .foregroundColor: fg(.labelColor), .paragraphStyle: para]))
            if l.inProgress {   // still transcribing this line → typing indicator inside the text
                out.append(NSAttributedString(string: l.text.isEmpty ? "…" : " …", attributes: [
                    .font: textFont, .foregroundColor: fg(.secondaryLabelColor), .paragraphStyle: para]))
            }
            if let t = l.translated, !t.isEmpty {
                out.append(NSAttributedString(string: "\n↳ ", attributes: [
                    .font: markFont, .foregroundColor: fg(.tertiaryLabelColor), .paragraphStyle: trans]))
                // The translation carries the SPEAKER's tint (source text stays neutral) — the two
                // layers separate at a glance instead of being two near-identical white lines.
                out.append(NSAttributedString(string: t, attributes: [
                    .font: transFont, .foregroundColor: fg(tint.withAlphaComponent(0.95)), .paragraphStyle: trans]))
            }
        }
        // Over a see-through backdrop the captions sit on whatever is behind the window — light slides,
        // white documents — and vanish. The two treatments that DON'T work: a blurred halo smears the
        // thin strokes, and a negative `strokeWidth` outlines the glyphs, which reads as a heavier
        // weight. Neither may touch the letterforms. So put the contrast BEHIND them, as broadcast
        // captions do: a dark plate hugging the text, drawn only when the backdrop can't do the job.
        if captionTextNeedsBackplate(backdropAlpha: backdrop.alphaValue) {
            out.addAttribute(.backgroundColor, value: NSColor.black.withAlphaComponent(0.8),
                             range: NSRange(location: 0, length: out.length))
        }
        textView.textStorage?.setAttributedString(out)
        textView.scrollToEndOfDocument(nil)
    }

    // User clicked the panel's close button → tear the session down (unless we closed it ourselves).
    func windowWillClose(_ notification: Notification) { if !suppressCloseCallback { onClose() } }
}
