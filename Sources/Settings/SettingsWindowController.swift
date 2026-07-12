import AppKit
import AVFoundation
import EventKit
import Foundation

/// A count field (minutes, seconds) is valid when empty (falls back to a default on save) or a
/// non-negative integer; anything else is a typo the parser can't read. Pure + selftested.
func numericFieldValid(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespaces)
    return t.isEmpty || (Int(t).map { $0 >= 0 } ?? false)
}

/// The Settings window: builds every pane, loads/saves prefs, and restarts the engine on Save — but
/// only when an engine-affecting pref actually changed (see engineKeys / engineSettingsDigest).
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSComboBoxDelegate {
    /// A field the parser can't read must LOOK broken while typing — schedule fields silently
    /// falling open to "record everything" is a privacy failure; a retention typo would silently
    /// keep the last saved period. Invalid input turns red and is ignored on save.
    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        if f === audioRawCombo || f === audioRetCombo { recolorRetentionCombos() }
        if f === calGatePadField || f === voiceField {
            f.textColor = numericFieldValid(f.stringValue) ? .labelColor : .systemRed
        }
    }

    fileprivate func recolorRetentionCombos() {
        for c in [audioRawCombo, audioRetCombo] {
            c.textColor = AudioArchivePolicy.parseRetentionDays(c.stringValue) != nil ? .labelColor : .systemRed
        }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { self.recolorRetentionCombos() }   // stringValue updates after this fires
    }
    private let onSave: () -> Void
    // Vertical navigation (System Settings style): a sidebar source list + one content pane at a
    // time, searchable. panesForTest doubles as the selftest hook (every pane must scroll etc.).
    private(set) var panesForTest: [(title: String, symbol: String, tint: NSColor, view: NSView, searchText: [String])] = []
    private let sidebarList = NSTableView()
    private let sidebarSearch = NSSearchField()
    private let paneContainer = NSView()
    private var visiblePaneIndexes: [Int] = []   // sidebar rows → pane indexes (search filters this)
    private var selectedPane = 0
    private var sectionGroupViews: [String: [NSView]] = [:]   // tag → section views, toggled as tabs
    private let segPopup = NSPopUpButton(), langPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let txtRetPopup = NSPopUpButton()
    private let audioRawCombo = NSComboBox(), audioRetCombo = NSComboBox()   // editable: any "45 days" works
    private let addAppPopup = NSPopUpButton()
    private let voiceField = NSTextField(), dirField = NSTextField(), audioDirField = NSTextField()
    private let customModelField = NSTextField()   // custom model URL or local path (overrides the popup)
    private let deepgramKeyField = NSSecureTextField()   // cloud live engines — the only off-device features
    private let openaiKeyField = NSSecureTextField()
    private let openaiBaseField = NSTextField()   // OpenAI-compatible proxy/gateway base URL ("" = official)
    private let gladiaKeyField = NSSecureTextField()
    private let elevenlabsKeyField = NSSecureTextField()  // ElevenLabs Scribe STT (best ko/ja accuracy)
    private let deeplKeyField = NSSecureTextField()        // DeepL translation key (cloud translator, opt-in)
    private let translateProviderPopup = NSPopUpButton()   // live-translation backend: Apple (on-device) | DeepL
    private let translateProviderValues = TranslationProvider.allCases.map(\.rawValue)
    private let translateProviderTitles = TranslationProvider.allCases.map(\.title)
    private let postProcessField = NSTextField()  // freeform post-process command (shell mode)
    private let ppModeSeg = NSSegmentedControl()  // Off / Automatic summary (built-in) / Custom command
    private let ppModeValues = ["off", "summary", "shell"], ppModeTitles = ["Off", "Automatic summary", "Custom command"]
    private let runnerPopup = NSPopUpButton()     // which agent CLI writes the summary
    private let runnerValues = ["claude", "codex", "gemini"], runnerTitles = ["Claude CLI", "Codex CLI", "Gemini CLI"]
    private let promptView = NSTextView()         // summary prompt — a real TEXT AREA (prompts are sentences)
    private let promptFileField = NSTextField()   // external prompt file — overrides the text when readable
    private let promptScroll = PassthroughScrollView()   // its bordered, scrolling host (wheel passes to the pane when it fits)
    private let summaryOutField = NSTextField()   // summary output dir ("" = next to the transcript)
    private let dailyBtn = NSSwitch()
    private let dailyTimePicker = NSDatePicker()  // HH:mm the digest becomes due
    private let dailyOutField = NSTextField()     // digest output dir ("" = alongside the summaries)
    private let dailyNameField = NSTextField()    // digest file-name template ("" = "{date}.md")
    private let updateBtn = NSSwitch()
    private let dailyPromptView = NSTextView()    // digest prompt — same text-area treatment as summary
    private let dailyPromptScroll = PassthroughScrollView()
    private let dailyPromptFileField = NSTextField()
    /// One switch per live-caption engine. The overlay's picker offers an engine only when its switch is
    /// on AND the engine is ready (key present / binary installed) — see `selectableLiveEngines`.
    private let engineSwitches: [(engine: LiveEngine, box: NSSwitch)] =
        LiveEngine.allCases.map { ($0, NSSwitch()) }
    private let savedLabel = NSTextField(labelWithString: "✓ Saved")   // transient confirmation for a non-closing Save
    private var savedFlash: DispatchWorkItem?
    private var flashGen = 0                          // fences a stale fade-completion from hiding a newer flash
    private(set) var footerButtonsForTest: [NSButton] = []
    private let hintsTermsField = NSTextField()   // hint terms (comma/newline separated)
    private let hintsFileField = NSTextField()    // external hints file path
    private let schedBtn = NSSwitch()
    private let calGateBtn = NSSwitch()          // record only while a calendar meeting is live
    private let calGatePadField = NSTextField()  // minutes to record before/after a meeting
    // Schedule is SELECTED, not typed (user, repeatedly): a 7-day multi-select + time-range pickers.
    private let daysSeg = NSSegmentedControl()          // Mon…Sun, multi-select (.selectAny)
    private let hoursRangesStack = NSStackView()        // one row per time range (start–end + remove)
    private weak var hoursControlView: NSView?          // the Hours control (rows + Add) — dimmed when off
    private let daySegKeys = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    private let hintsCalBtn = NSSwitch()
    private let excludeTokens = NSTokenField()   // multiple bundle ids as tokens
    // Calendar titling: a scrollable checkbox list of the user's calendars (none checked = all).
    private var calChecks: [(name: String, box: NSButton)] = []
    private let keepAudioBtn = NSSwitch()
    private let vadBtn = NSSwitch()
    private let calBtn = NSSwitch()
    private let loginBtn = NSSwitch()
    private let systemAudioBtn = NSSwitch()
    private let echoBtn = NSSwitch()
    private var runningAppIds: [String] = []

    private let segValues = [900, 1800, 3600, 7200], segTitles = ["15 min", "30 min", "1 hour", "2 hours"]
    private let langValues = ["auto", "ko", "ja", "en"], langTitles = ["Auto-detect", "Korean", "Japanese", "English"]
    private let transcriptLangPopup = NSPopUpButton()
    private let tLangValues = ["", "en", "ko", "ja"], tLangTitles = ["System", "English", "한국어", "日本語"]
    private let modelNames = WhisperCatalog.all.map { $0.name }   // popup order matches WhisperCatalog.all
    private let retValues = [7, 30, 90, 180, 365, 0]
    private let retTitles = ["7 days", "30 days", "90 days", "180 days", "1 year", "Unlimited"]

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
        let w = EditableWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
                               styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "macrec — Settings"
        super.init(window: w)
        w.delegate = self
        buildForm()
        load()
        // Fixed comfortable size (sidebar 200 + a 540pt content column). Panes taller than this
        // scroll, with a permanent scrollbar — no window auto-resizing (user ask).
        w.setContentSize(NSSize(width: 880, height: 600))
        selectPane(selectedPane)
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildForm() {
        segPopup.addItems(withTitles: segTitles); langPopup.addItems(withTitles: langTitles)
        transcriptLangPopup.addItems(withTitles: tLangTitles)
        translateProviderPopup.addItems(withTitles: translateProviderTitles)
        modelPopup.addItems(withTitles: WhisperCatalog.all.map { $0.label })
        txtRetPopup.addItems(withTitles: retTitles)
        audioRawCombo.addItems(withObjectValues: ["3 days", "7 days", "14 days", "30 days", "Don't compress"])
        audioRetCombo.addItems(withObjectValues: ["30 days", "90 days", "180 days", "1 year", "Unlimited"])
        for c in [audioRawCombo, audioRetCombo] {
            c.translatesAutoresizingMaskIntoConstraints = false
            c.widthAnchor.constraint(equalToConstant: 140).isActive = true
            c.completes = true
            c.delegate = self   // red-on-invalid, same treatment as the schedule fields
        }
        for f in [voiceField, dirField, audioDirField, customModelField, deepgramKeyField, openaiKeyField, openaiBaseField, gladiaKeyField, elevenlabsKeyField, deeplKeyField, postProcessField, promptFileField, calGatePadField] { f.translatesAutoresizingMaskIntoConstraints = false }
        voiceField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        calGatePadField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        dirField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        audioDirField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        customModelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        customModelField.placeholderString = "https://…/ggml-model.bin  or  /path/to/model.bin"
        deepgramKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        deepgramKeyField.placeholderString = "Deepgram API key"
        openaiKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        openaiKeyField.placeholderString = "sk-…"
        openaiBaseField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        gladiaKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        gladiaKeyField.placeholderString = "Gladia API key"
        elevenlabsKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        elevenlabsKeyField.placeholderString = "ElevenLabs API key"
        deeplKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        deeplKeyField.placeholderString = "DeepL API key (…:fx for the free tier)"
        promptFileField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        promptFileField.placeholderString = "~/notes/summary-prompt.md"
        postProcessField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        postProcessField.placeholderString = "~/bin/my-pipeline.sh"
        summaryOutField.translatesAutoresizingMaskIntoConstraints = false
        summaryOutField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        summaryOutField.placeholderString = "empty = next to the transcript"
        dailyOutField.translatesAutoresizingMaskIntoConstraints = false
        dailyOutField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        dailyOutField.placeholderString = "empty = alongside the summaries"
        dailyNameField.translatesAutoresizingMaskIntoConstraints = false
        dailyNameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        dailyNameField.placeholderString = dailyDigestNameDefault
        dailyTimePicker.datePickerStyle = .textFieldAndStepper
        dailyTimePicker.datePickerElements = .hourMinute
        dailyTimePicker.translatesAutoresizingMaskIntoConstraints = false
        schedBtn.target = self; schedBtn.action = #selector(scheduleToggled)
        calGateBtn.target = self; calGateBtn.action = #selector(calGateToggled)
        // Days: a 7-segment multi-select (Mon…Sun) — click to toggle, no typing, no invalid state.
        daysSeg.segmentCount = daySegKeys.count
        daysSeg.trackingMode = .selectAny
        daysSeg.segmentDistribution = .fillEqually
        daysSeg.translatesAutoresizingMaskIntoConstraints = false
        for (i, k) in daySegKeys.enumerated() { daysSeg.setLabel(k.capitalized, forSegment: i) }
        // Hours: a stack of time-range rows (start–end pickers + remove), plus an Add button below.
        hoursRangesStack.orientation = .vertical
        hoursRangesStack.alignment = .leading
        hoursRangesStack.spacing = 6
        hoursRangesStack.translatesAutoresizingMaskIntoConstraints = false
        for f in [hintsTermsField, hintsFileField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        hintsTermsField.placeholderString = "Kubernetes, gRPC, John Doe, …"
        hintsFileField.placeholderString = "~/notes/hints.txt"
        // PATH-carrying fields: a long path used to truncate at the TAIL, hiding the part that matters
        // (user report on "Save summary to"). Truncate the HEAD instead ("…/notes/summaries"), widen,
        // and mirror the full value into the tooltip on load (see load()).
        for f in [dirField, audioDirField, customModelField, hintsFileField, promptFileField,
                  summaryOutField, postProcessField] {
            f.cell?.lineBreakMode = .byTruncatingHead
            f.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        // Multiline prompt editor (user feedback: a one-line field is too small for a real prompt).
        promptScroll.translatesAutoresizingMaskIntoConstraints = false
        promptScroll.hasVerticalScroller = true
        promptScroll.autohidesScrollers = true
        promptScroll.borderType = .bezelBorder
        promptScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        promptScroll.heightAnchor.constraint(equalToConstant: 84).isActive = true
        promptView.isRichText = false
        promptView.font = .systemFont(ofSize: 12)
        promptView.textContainerInset = NSSize(width: 4, height: 6)
        promptView.autoresizingMask = [.width]
        promptView.isVerticallyResizable = true
        promptView.minSize = NSSize(width: 0, height: 0)
        promptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        promptView.textContainer?.widthTracksTextView = true
        promptScroll.documentView = promptView
        // Daily digest gets the SAME prompt affordances as the per-meeting summary (user ask).
        dailyPromptScroll.translatesAutoresizingMaskIntoConstraints = false
        dailyPromptScroll.hasVerticalScroller = true
        dailyPromptScroll.autohidesScrollers = true
        dailyPromptScroll.borderType = .bezelBorder
        dailyPromptScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        dailyPromptScroll.heightAnchor.constraint(equalToConstant: 66).isActive = true
        dailyPromptView.isRichText = false
        dailyPromptView.font = .systemFont(ofSize: 12)
        dailyPromptView.textContainerInset = NSSize(width: 4, height: 6)
        dailyPromptView.autoresizingMask = [.width]
        dailyPromptView.isVerticallyResizable = true
        dailyPromptView.minSize = NSSize(width: 0, height: 0)
        dailyPromptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        dailyPromptView.textContainer?.widthTracksTextView = true
        dailyPromptScroll.documentView = dailyPromptView
        dailyPromptFileField.translatesAutoresizingMaskIntoConstraints = false
        dailyPromptFileField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        dailyPromptFileField.placeholderString = "empty = the prompt above"
        ppModeSeg.segmentCount = ppModeTitles.count
        for (i, t) in ppModeTitles.enumerated() { ppModeSeg.setLabel(t, forSegment: i) }
        ppModeSeg.selectedSegment = 0
        ppModeSeg.segmentStyle = .texturedRounded
        ppModeSeg.target = self; ppModeSeg.action = #selector(ppModeChanged)
        runnerPopup.addItems(withTitles: runnerTitles)
        // Vendor badges on each runner so the picker reads at a glance (Claude / Codex / Gemini).
        let runnerBadges = [vendorBadge("sparkle", NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)),   // Claude — coral
                            vendorBadge("chevron.left.forwardslash.chevron.right", NSColor(srgbRed: 0.06, green: 0.64, blue: 0.50, alpha: 1)),  // Codex — OpenAI green
                            vendorBadge("sparkles", NSColor(srgbRed: 0.26, green: 0.52, blue: 0.96, alpha: 1))]  // Gemini — Google blue
        for (i, badge) in runnerBadges.enumerated() { runnerPopup.item(at: i)?.image = badge }
        openaiBaseField.placeholderString = "empty = api.openai.com"

        excludeTokens.translatesAutoresizingMaskIntoConstraints = false
        excludeTokens.tokenizingCharacterSet = CharacterSet(charactersIn: ", ")
        excludeTokens.placeholderString = "e.g. com.spotify.client"
        excludeTokens.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        populateRunningApps()

        let calListCell = buildCalendarList()
        let hoursControl = buildHoursControl()

        // One factory for every "path field + Choose…" row, so spacing and hugging can't drift.
        func pathStack(_ field: NSTextField, _ action: Selector) -> (stack: NSStackView, button: NSButton) {
            let b = NSButton(title: "Choose…", target: self, action: action)
            b.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let s = NSStackView(views: [field, b])
            s.orientation = .horizontal; s.spacing = 6; s.distribution = .fill
            return (s, b)
        }
        let dirStack = pathStack(dirField, #selector(chooseDir)).stack
        let audioStack = pathStack(audioDirField, #selector(chooseAudioDir)).stack
        let summaryStack = pathStack(summaryOutField, #selector(chooseSummaryDir)).stack
        let dailyStack = pathStack(dailyOutField, #selector(chooseDailyDir)).stack
        let promptFileStack = pathStack(promptFileField, #selector(choosePromptFile)).stack
        let dailyPromptFileStack = pathStack(dailyPromptFileField, #selector(chooseDailyPromptFile)).stack
        let hintsFileStack = pathStack(hintsFileField, #selector(chooseHintsFile)).stack
        // Switches read oversized next to 13pt row text — use the small control size so they sit in
        // proportion, like System Settings.
        for s in [systemAudioBtn, echoBtn, vadBtn, keepAudioBtn, schedBtn, dailyBtn, updateBtn, loginBtn, hintsCalBtn, calBtn]
                 + engineSwitches.map(\.box) {
            s.controlSize = .small
        }

        // ── Grouped row-card vocabulary (benchmarked to cmux / iTerm) ──
        // A pane is a list of Sections; a Section is an optional gray header + an intro note + a
        // rounded card of Rows. A Row is a title (+ optional description) on the LEFT and one control
        // on the RIGHT — or, for wide controls (text fields, path pickers, editors), the control
        // stacked full-width BELOW the title. Roles are explicit here, not derived from view types.
        struct Row { let name: String; let desc: String?; let control: NSView?; let wide: Bool }
        struct Section {
            let header: String?; let note: String?; let rows: [Row]; let group: String?; let icon: NSImage?
            // `group` tags a section so a control (e.g. the Summaries Mode segment) can show/hide it
            // as a real tab. nil = always visible. `icon` is an optional vendor badge shown before the header.
            init(header: String?, note: String?, rows: [Row], group: String? = nil, icon: NSImage? = nil) {
                self.header = header; self.note = note; self.rows = rows; self.group = group; self.icon = icon
            }
        }
        func r(_ name: String, _ control: NSView?, _ desc: String? = nil, wide: Bool = false) -> Row {
            Row(name: name, desc: desc, control: control, wide: wide)
        }
        // A boolean row: the switch is the right-hand control; its old checkbox title becomes the
        // row title (a switch carries no label of its own).
        func sw(_ b: NSSwitch, _ name: String, _ desc: String? = nil) -> Row {
            Row(name: name, desc: desc, control: b, wide: false)
        }

        // One row view: full-width, self-sizing. Inline layout for compact controls, stacked layout
        // (control below the text) for wide ones so a 340pt field never fights the title for width.
        // The description is pinned to its ACTUAL available trailing edge and wraps to that width —
        // so at a wide window it stays one line instead of wrapping at a fixed 300pt.
        func rowView(_ row: Row) -> NSView {
            let host = NSView(); host.translatesAutoresizingMaskIntoConstraints = false
            let name = NSTextField(labelWithString: row.name)
            name.font = .systemFont(ofSize: 13)
            name.textColor = .labelColor
            name.translatesAutoresizingMaskIntoConstraints = false
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            host.addSubview(name)
            let desc: WrappingLabel? = row.desc.map { wrappingCaption($0) }
            if let d = desc { host.addSubview(d) }
            var cs: [NSLayoutConstraint] = [
                name.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
                name.topAnchor.constraint(equalTo: host.topAnchor, constant: 11),
            ]
            // The x edge the text (name + desc) may extend to before hitting the control.
            let textTrailing: NSLayoutXAxisAnchor
            let textTrailingInset: CGFloat

            if let control = row.control {
                control.translatesAutoresizingMaskIntoConstraints = false   // every control is autolayout'd here
                // A row's name is a sibling label, and AppKit never infers a control's name from a view
                // that merely sits next to it. `NSButton(checkboxWithTitle:)` carried its own title, so
                // switching to NSSwitch/popups left every setting unlabelled to VoiceOver.
                if control.accessibilityLabel()?.isEmpty ?? true { control.setAccessibilityLabel(row.name) }
                host.addSubview(control)
                if row.wide {
                    // Title (+desc) on top, control stretched full-width beneath — fields fill the card.
                    control.setContentHuggingPriority(.defaultLow, for: .horizontal)
                    textTrailing = host.trailingAnchor; textTrailingInset = -14
                    let below = desc ?? name
                    cs += [
                        control.topAnchor.constraint(equalTo: below.bottomAnchor, constant: 8),
                        control.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
                        control.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
                        control.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -12),
                    ]
                } else {
                    // Title left, control right (centered); the text may extend up to the control.
                    control.setContentHuggingPriority(.required, for: .horizontal)
                    control.setContentCompressionResistancePriority(.required, for: .horizontal)
                    textTrailing = control.leadingAnchor; textTrailingInset = -14
                    let bottomAnchorView = desc ?? name
                    cs += [
                        control.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
                        control.centerYAnchor.constraint(equalTo: host.centerYAnchor),
                        bottomAnchorView.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -11),
                    ]
                }
            } else {
                textTrailing = host.trailingAnchor; textTrailingInset = -14
                let bottomAnchorView = desc ?? name
                cs += [bottomAnchorView.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -11)]
            }

            cs.append(name.trailingAnchor.constraint(lessThanOrEqualTo: textTrailing, constant: textTrailingInset))
            if let d = desc {
                cs += [
                    d.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
                    d.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
                    d.trailingAnchor.constraint(equalTo: textTrailing, constant: textTrailingInset),
                ]
            }
            NSLayoutConstraint.activate(cs)
            return host
        }

        // A rounded card holding rows separated by hairline dividers (dividers inset from the left,
        // matching the row text — the System Settings / cmux idiom).
        func card(_ rows: [Row]) -> SectionCard {
            let box = SectionCard()
            box.translatesAutoresizingMaskIntoConstraints = false
            box.wantsLayer = true
            box.layer?.cornerRadius = 8
            box.layer?.cornerCurve = .continuous
            box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            box.layer?.borderWidth = 1
            box.layer?.borderColor = NSColor.separatorColor.cgColor
            let stack = NSStackView()
            stack.orientation = .vertical; stack.spacing = 0; stack.alignment = .leading
            stack.translatesAutoresizingMaskIntoConstraints = false
            for (i, row) in rows.enumerated() {
                if i > 0 {
                    let div = NSBox(); div.boxType = .separator
                    div.translatesAutoresizingMaskIntoConstraints = false
                    stack.addArrangedSubview(div)
                    div.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14).isActive = true
                    div.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
                }
                let rv = rowView(row)
                stack.addArrangedSubview(rv)
                rv.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
                rv.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
            }
            box.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: box.topAnchor),
                stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            ])
            return box
        }

        // Collect every visible string in a pane for the sidebar search index (title + section
        // headers + notes + each row's name & description).
        func searchText(of title: String, _ sections: [Section]) -> [String] {
            var out = [title]
            for s in sections {
                if let h = s.header { out.append(h) }
                if let n = s.note { out.append(n) }
                for row in s.rows { out.append(row.name); if let d = row.desc { out.append(d) } }
            }
            return out.filter { !$0.isEmpty }
        }

        func pane(_ title: String, _ symbol: String, _ tint: NSColor, _ sections: [Section]) {
            let outer = NSStackView()
            outer.orientation = .vertical; outer.alignment = .leading; outer.spacing = 0
            outer.translatesAutoresizingMaskIntoConstraints = false

            let bigTitle = NSTextField(labelWithString: title)
            bigTitle.font = .systemFont(ofSize: 15, weight: .semibold)   // modest head — was 20pt, too shouty (user)
            bigTitle.textColor = .labelColor
            outer.addArrangedSubview(bigTitle)
            outer.setCustomSpacing(14, after: bigTitle)

            var fullWidth: [NSView] = []   // views that must stretch to the pane width
            for (si, s) in sections.enumerated() {
                var groupViews: [NSView] = []   // header+note+card of this section (for show/hide as a tab)
                if let h = s.header, h != title {   // skip a header that just echoes the pane title
                    let hl = NSTextField(labelWithString: h)   // normal case — not shouty all-caps (user)
                    hl.font = .systemFont(ofSize: 13, weight: .semibold)
                    hl.textColor = .secondaryLabelColor
                    let headerView: NSView
                    if let icon = s.icon {   // vendor badge before the name, for at-a-glance identity
                        let iv = NSImageView(image: icon)
                        iv.translatesAutoresizingMaskIntoConstraints = false
                        iv.widthAnchor.constraint(equalToConstant: 18).isActive = true
                        iv.heightAnchor.constraint(equalToConstant: 18).isActive = true
                        let hs = NSStackView(views: [iv, hl]); hs.orientation = .horizontal
                        hs.spacing = 7; hs.alignment = .centerY
                        headerView = hs
                    } else {
                        headerView = hl
                    }
                    outer.addArrangedSubview(headerView)
                    outer.setCustomSpacing(7, after: headerView)
                    groupViews.append(headerView)
                }
                if let n = s.note {
                    let nl = wrappingCaption(n)   // self-sizing: fills the pane width, wraps only if needed
                    outer.addArrangedSubview(nl)
                    outer.setCustomSpacing(s.rows.isEmpty ? 20 : 8, after: nl)
                    fullWidth.append(nl); groupViews.append(nl)
                }
                if !s.rows.isEmpty {
                    let c = card(s.rows)
                    outer.addArrangedSubview(c)
                    outer.setCustomSpacing(si == sections.count - 1 ? 0 : 20, after: c)
                    fullWidth.append(c); groupViews.append(c)
                }
                if let g = s.group { sectionGroupViews[g, default: []].append(contentsOf: groupViews) }
            }

            let doc = FlippedDocView()   // flipped so the form starts at the TOP of the scroll area
            doc.translatesAutoresizingMaskIntoConstraints = false
            doc.addSubview(outer)
            let scroll = NSScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .legacy     // a permanent scrollbar (user: always visible, not overlay)
            scroll.autohidesScrollers = false
            scroll.drawsBackground = false
            scroll.documentView = doc
            let paneView = NSView(); paneView.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: paneView.topAnchor),
                scroll.leadingAnchor.constraint(equalTo: paneView.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: paneView.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: paneView.bottomAnchor),
                doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                outer.topAnchor.constraint(equalTo: doc.topAnchor, constant: 22),
                outer.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 26),
                outer.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -26),
                outer.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -24),
            ])
            for v in fullWidth { v.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true }
            panesForTest.append((title: title, symbol: symbol, tint: tint, view: paneView,
                                 searchText: searchText(of: title, sections)))
        }
        // A concise reusable label for the "record around the clock" phrase.
        pane("Recording", "record.circle", .systemRed, [
            Section(header: "Capture", note: nil, rows: [
                r("Segment length", segPopup, "Starts a new recording file on the hour."),
                sw(systemAudioBtn, "Capture system audio", "Record other participants (system output), not only your mic."),
                sw(echoBtn, "Reduce mic echo", "Experimental — suppress speaker sound leaking back into the mic."),
                r("Minimum speech", voiceField, "Seconds of speech required before a segment is saved."),
                sw(vadBtn, "Remove noise & silence", "Voice-activity detection trims dead air from recordings."),
            ]),
            Section(header: "Excluded apps", note: nil, rows: [
                r("Never capture", excludeTokens, "These apps are left out of the recorded system-audio "
                  + "mix. They keep playing out loud, so your microphone may still pick them up.", wide: true),
                r("Add a running app", addAppPopup, wide: true),
            ]),
        ])
        pane("Schedule", "calendar.badge.clock", .systemOrange, [
            Section(header: "When to record", note: nil, rows: [
                sw(schedBtn, "Record only on a schedule", "Off = record around the clock."),
                r("Days", daysSeg, "Leave all off for every day.", wide: true),
                r("Hours", hoursControl, "The gap between two ranges is your lunch break; a range that "
                  + "ends before it starts wraps past midnight. No ranges = all hours.", wide: true),
            ]),
            Section(header: "Calendar", note: nil, rows: [
                sw(calGateBtn, "Record only during calendar meetings",
                   "Also gate on a live meeting from your Titling calendars. Needs Calendar access — "
                   + "without it this is ignored (recording is never silently stopped)."),
                r("± minutes", calGatePadField, "Also record this many minutes before and after a meeting."),
            ]),
            Section(header: nil, note: "Off-hours the tray shows ⏸ Off-hours (schedule); between meetings "
                    + "⏸ No meeting (calendar). A manual Pause/Resume overrides both until the schedule's "
                    + "next boundary.", rows: []),
        ])
        pane("Storage", "archivebox", .systemBrown, [
            Section(header: "Transcripts", note: nil, rows: [
                r("Keep for", txtRetPopup),
                r("Folder", dirStack, wide: true),
            ]),
            Section(header: "Audio", note: nil, rows: [
                sw(keepAudioBtn, "Keep audio (WAV)", "Save the raw recording next to the transcript."),
                r("Compress after", audioRawCombo, "Recent recordings stay WAV; older ones archive to AAC "
                  + "(~⅛ the size). Type any period — 45 days, 6 months, 1 year."),
                r("Delete after", audioRetCombo, "Audio older than this is deleted, raw or compressed. "
                  + "Unlimited keeps it forever."),
                r("Folder", audioStack, wide: true),
            ]),
        ])
        pane("Transcription", "text.quote", .systemPurple, [
            Section(header: "Model", note: nil, rows: [
                r("Model", modelPopup),
                r("Custom model", customModelField, "A URL or path to a ggml model — overrides the picker above.", wide: true),
                r("Spoken language", langPopup, "The language whisper transcribes."),
                r("Transcript file language", transcriptLangPopup, "Headings and labels of the saved markdown file (not the speech)."),
            ]),
            Section(header: "Hints", note: nil, rows: [
                r("Terms", hintsTermsField, "Team/product names, jargon, people — comma or newline separated. "
                  + "Biases recognition so proper nouns stop coming out mangled.", wide: true),
                r("Hints file", hintsFileStack, "One term per line, # comments — merged with the terms above.", wide: true),
                sw(hintsCalBtn, "Add title & attendees from Calendar", "Feed the meeting's calendar event in as hints."),
            ]),
        ])
        pane("Titling", "textformat", .systemGreen, [
            Section(header: "Titling", note: "How each saved transcript is named.", rows: [
                sw(calBtn, "Title from calendar events", "Name transcripts after the meeting on your calendar."),
                r("Calendars", calListCell, "Checked calendars are matched; none checked = all of them.", wide: true),
            ]),
        ])
        pane("Summaries", "text.append", .systemIndigo, [
            Section(header: "Post-processing", note: "Runs after each hourly transcript is saved.", rows: [
                r("Mode", ppModeSeg, "Automatic summary is built in — pick who writes it, or take full "
                  + "control with a custom command.", wide: true),
            ]),
            // Mode is a tab: only the selected mode's sections show (see updatePostProcessEnabled).
            Section(header: nil, note: "Post-processing is off — transcripts are saved as-is.",
                    rows: [], group: "pp.off"),
            Section(header: "Automatic summary", note: nil, rows: [
                r("Summarize with", runnerPopup),
                r("Prompt", promptScroll, "Default asks for key points, decisions, and action items — "
                  + "answered in the transcript's language.", wide: true),
                r("Prompt file", promptFileStack, "Overrides the text above when readable — keep the prompt "
                  + "in your notes repo and iterate without opening Settings.", wide: true),
                r("Save summary to", summaryStack, "Summaries land in monthly folders (YYYY-MM/<name>.md). "
                  + "Empty = next to the transcript.", wide: true),
            ], group: "pp.summary"),
            Section(header: "Daily digest", note: nil, rows: [
                sw(dailyBtn, "Write a daily digest", "Roll the day's meeting summaries into one file."),
                r("Write at", dailyTimePicker),
                r("Prompt", dailyPromptScroll, wide: true),
                r("Prompt file", dailyPromptFileStack, "Overrides the text above when readable.", wide: true),
                r("Save digest to", dailyStack, "Once a day, the day's summaries roll up into a monthly "
                  + "folder (YYYY-MM/) under the folder you pick. Empty = alongside the summaries. "
                  + "A slept-through deadline catches up on wake.", wide: true),
                r("File name", dailyNameField, "Tokens: {date} → 2026-07-09, {month} → 2026-07. "
                  + "Empty uses \(dailyDigestNameDefault).", wide: true),
            ], group: "pp.summary"),
            Section(header: "Custom command", note: nil, rows: [
                r("Command", postProcessField, "Freeform: runs in a login shell with the transcript path "
                  + "appended as the last argument.", wide: true),
            ], group: "pp.shell"),
        ])
        // Each engine gets a switch; the overlay's picker lists only engines that are ON and READY.
        // An engine missing its key says so right here instead of failing later inside the caption area.
        func engineSwitch(_ e: LiveEngine) -> NSSwitch { engineSwitches.first { $0.engine == e }!.box }
        // In a vendor section the header already names the engine, so the row says what the switch does;
        // under "On-device" the row IS the engine's name, because two engines share that header.
        func engineRow(_ e: LiveEngine, _ desc: String, named: Bool = false) -> Row {
            sw(engineSwitch(e), named ? e.plainTitle : "Use for live captions",
               desc + (e.notReadyReason.map { " \($0)" } ?? ""))
        }
        pane("Live Captions", "captions.bubble", .systemTeal, [
            Section(header: nil, note: "Cloud caption engines stream audio off-device — only while the live "
                    + "overlay runs with that engine selected. Keys are stored in the Keychain, never in "
                    + "preferences or backups. Pick the engine in the overlay's control bar.", rows: []),
            Section(header: "On-device", note: nil, rows: [
                engineRow(.apple, "Apple's on-device recognizer — lowest latency, no network.", named: true),
                engineRow(.whisper, "whisper.cpp on the same model as the saved transcript — slower, more accurate.", named: true),
            ]),
            Section(header: "Deepgram", note: nil, rows: [
                engineRow(.deepgram, "Streaming cloud recognizer (model: nova-2)."),
                r("API key", deepgramKeyField, "Get a key at console.deepgram.com (model: nova-2).", wide: true),
            ], icon: vendorBadge("waveform", NSColor(srgbRed: 0.07, green: 0.80, blue: 0.55, alpha: 1))),
            Section(header: "OpenAI", note: nil, rows: [
                engineRow(.openai, "Realtime transcription over a websocket (gpt-4o-transcribe)."),
                r("API key", openaiKeyField, "platform.openai.com — or a key your gateway accepts (gpt-4o-transcribe).", wide: true),
                r("Base URL", openaiBaseField, "OpenAI-compatible gateway / corporate proxy. Leave empty for api.openai.com.", wide: true),
            ], icon: vendorBadge("sparkles", NSColor(srgbRed: 0.06, green: 0.64, blue: 0.50, alpha: 1))),
            Section(header: "Gladia", note: nil, rows: [
                engineRow(.gladia, "Streaming cloud recognizer with broad language coverage."),
                r("API key", gladiaKeyField, "app.gladia.io — broad language coverage incl. Korean streaming.", wide: true),
            ], icon: vendorBadge("globe", NSColor(srgbRed: 0.42, green: 0.31, blue: 0.95, alpha: 1))),
            Section(header: "ElevenLabs", note: nil, rows: [
                engineRow(.elevenlabs, "Scribe v2 Realtime — strongest Korean/Japanese accuracy (streaming)."),
                r("API key", elevenlabsKeyField, "elevenlabs.io — best-in-class ko/ja transcription.", wide: true),
            ], icon: vendorBadge("waveform.circle", NSColor(srgbRed: 0.42, green: 0.45, blue: 0.50, alpha: 1))),
            Section(header: "Translation", note: "Translates captions into the target language you pick in the "
                    + "overlay's control bar. Apple runs on-device; DeepL is a cloud service (markedly better "
                    + "for JA↔KO) that needs its own key — with it selected, caption text is sent to DeepL's "
                    + "servers. DeepL falls back to Apple when no key is set.", rows: [
                r("Provider", translateProviderPopup, "Apple (on-device) or DeepL (cloud)."),
                r("DeepL API key", deeplKeyField, "Free or Pro key from deepl.com/pro-api. Only used when the "
                  + "provider is DeepL; source language is auto-detected.", wide: true),
            ], icon: vendorBadge("character.bubble", NSColor(srgbRed: 0.05, green: 0.44, blue: 0.90, alpha: 1))),
        ])
        pane("General", "gearshape", .systemGray, [
            Section(header: "General", note: nil, rows: [
                sw(loginBtn, "Start at login", "Launch macrec on login for around-the-clock recording."),
                sw(updateBtn, "Check for updates daily", "Silently checks GitHub once a day and notifies only "
                  + "when a new release is out. Check now from the tray menu → Check for Updates…"),
            ]),
        ])

        // Save applies in place and leaves Settings open, so it must announce itself: the footer flashes.
        let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveSettings)); saveBtn.keyEquivalent = "\r"
        let closeBtn = NSButton(title: "Close", target: self, action: #selector(closeOnly)); closeBtn.keyEquivalent = "\u{1b}"
        savedLabel.font = .systemFont(ofSize: 12)
        savedLabel.textColor = .secondaryLabelColor
        savedLabel.isHidden = true
        let btns = NSStackView(views: [savedLabel, closeBtn, saveBtn]); btns.orientation = .horizontal; btns.spacing = 10
        btns.translatesAutoresizingMaskIntoConstraints = false
        footerButtonsForTest = [closeBtn, saveBtn]

        // ── vertical navigation: search + source list on the left, one pane on the right ──
        sidebarSearch.placeholderString = "Search"
        sidebarSearch.target = self
        sidebarSearch.action = #selector(searchChanged)
        sidebarSearch.sendsSearchStringImmediately = true
        sidebarSearch.translatesAutoresizingMaskIntoConstraints = false

        sidebarList.style = .sourceList
        sidebarList.headerView = nil
        sidebarList.rowHeight = 34   // more breathing room between rows (was cramped)
        sidebarList.focusRingType = .none
        // Source-list metrics (inset rows, type-select). The selection PILL itself is drawn by
        // SidebarRowView.drawSelection — the stock source-list drawing dims whenever the table isn't
        // first responder, which is what made the selection appear to blink blue.
        sidebarList.selectionHighlightStyle = .sourceList
        sidebarList.addTableColumn(NSTableColumn(identifier: .init("pane")))
        sidebarList.dataSource = self
        sidebarList.delegate = self
        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebarList
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarSearch); sidebar.addSubview(sidebarScroll)

        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        // General leads (identity/behavior first), then the recording pipeline in flow order.
        // Pipeline order: identity → capture → when → where → text → title → summary → live mode.
        let paneOrder = ["General", "Recording", "Schedule", "Storage", "Transcription", "Titling", "Summaries", "Live Captions"]
        panesForTest.sort { (paneOrder.firstIndex(of: $0.title) ?? 99) < (paneOrder.firstIndex(of: $1.title) ?? 99) }
        visiblePaneIndexes = Array(panesForTest.indices)
        sidebarList.reloadData()

        let sep = NSBox(); sep.boxType = .separator; sep.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(sidebar); content.addSubview(paneContainer); content.addSubview(sep); content.addSubview(btns)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 200),
            sidebarSearch.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 12),
            sidebarSearch.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            sidebarSearch.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            sidebarScroll.topAnchor.constraint(equalTo: sidebarSearch.bottomAnchor, constant: 8),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            paneContainer.topAnchor.constraint(equalTo: content.topAnchor),
            paneContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            paneContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            paneContainer.bottomAnchor.constraint(equalTo: sep.topAnchor),
            sep.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sep.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: btns.topAnchor, constant: -10),
            btns.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            btns.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        window?.contentView = content
        selectPane(0)
        sidebarList.selectRowIndexes([0], byExtendingSelection: false)
    }

    /// Swap the visible pane. The container hosts exactly one pane at a time (same views the old
    /// tabs held — load()/save() field wiring is untouched). The window is a FIXED size; a pane taller
    /// than it scrolls (user ask: default scroll, permanent scrollbar — no auto-resizing window).
    private func selectPane(_ index: Int) {
        guard panesForTest.indices.contains(index) else { return }
        selectedPane = index
        paneContainer.subviews.forEach { $0.removeFromSuperview() }
        let v = panesForTest[index].view
        v.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: paneContainer.topAnchor),
            v.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor),
        ])
    }

    /// Count PassthroughScrollViews across every built pane — proves the nested-scroll fix is wired
    /// into the real view tree (prompt, daily-prompt, calendar), not just the declared field types.
    var passthroughScrollCountForTest: Int {
        func count(_ v: NSView) -> Int {
            (v is PassthroughScrollView ? 1 : 0) + v.subviews.reduce(0) { $0 + count($1) }
        }
        return panesForTest.reduce(0) { $0 + count($1.view) }
    }

    /// Test hooks for the Summaries Mode tab: set the mode and read back whether a section group is
    /// fully shown (all its views visible). Lets selftest prove the tab swaps sections, not greys them.
    /// Test hook — internal so Sources/Selftest.swift can reach it.
    func setPPModeForTest(_ raw: String) {
        ppModeSeg.selectedSegment = ppModeValues.firstIndex(of: raw) ?? 0
        updatePostProcessEnabled()
    }
    /// Test hook — internal so Sources/Selftest.swift can reach it.
    func ppGroupVisibleForTest(_ g: String) -> Bool {
        let vs = sectionGroupViews[g] ?? []
        return !vs.isEmpty && vs.allSatisfy { !$0.isHidden }
    }

    /// The scroll document inside a pane view (its fitting height drives the snapshot capture size).
    private func paneDoc(in v: NSView) -> NSView? {
        if let sv = v as? NSScrollView { return sv.documentView }
        for s in v.subviews { if let d = paneDoc(in: s) { return d } }
        return nil
    }

    /// UI TEST KIT (see `macrec settings-snapshot`): render every pane to a PNG so a human — or the
    /// next build — can actually LOOK at the Settings window instead of trusting structural checks.
    /// Returns the files written. This exists because a "structurally valid" pane (grids present)
    /// shipped visually broken twice; snapshots make the breakage impossible to miss.
    func snapshotAllPanes(to dir: URL) -> [URL] {
        load()
        guard let win = window, let content = win.contentView else { return [] }
        let appearance = win.effectiveAppearance   // render in the user's real (likely dark) appearance
        var written: [URL] = []
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runtimeSize = NSSize(width: 880, height: 600)      // the real, fixed runtime size
        for i in panesForTest.indices {
            win.setContentSize(runtimeSize)
            sidebarList.selectRowIndexes([i], byExtendingSelection: false)   // drives selectPane via delegate
            selectPane(i)
            content.layoutSubtreeIfNeeded()
            // Grow the window to the pane's full document height, so a snapshot shows the WHOLE pane.
            // Rendering `content.bounds` at the runtime size cropped everything past the fold: the
            // bottom of Summaries and the entire Gladia section had never been looked at by anyone.
            if let doc = paneDoc(in: paneContainer) {
                let full = snapshotContentHeight(runtime: runtimeSize.height,
                                                 document: doc.fittingSize.height + snapshotChromeHeight)
                if full > runtimeSize.height {
                    win.setContentSize(NSSize(width: runtimeSize.width, height: full))
                    content.layoutSubtreeIfNeeded()
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            let bounds = content.bounds
            guard bounds.width > 1, bounds.height > 1 else { continue }
            // Composite the whole hierarchy over the window background, in the real appearance:
            // fill windowBackgroundColor, then draw the view tree. This matches what the user
            // sees (white labels on a dark pane) — an offscreen PDF alone dropped the background
            // and made dark-mode labels vanish on a white page.
            let img = NSImage(size: bounds.size)
            img.lockFocus()
            appearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                NSRect(origin: .zero, size: bounds.size).fill()
                if let ctx = NSGraphicsContext.current {
                    content.displayIgnoringOpacity(bounds, in: ctx)
                }
            }
            img.unlockFocus()
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let safe = panesForTest[i].title.replacingOccurrences(of: "/", with: "-")
            let url = dir.appendingPathComponent(String(format: "pane-%d-%@.png", i, safe))
            try? png.write(to: url)
            written.append(url)
        }
        return written
    }

    /// AUTOMATED UI REGRESSION TEST (runs in selftest / CI, headless). Lays out every pane at a
    /// real window size and returns human-readable layout defects: any control collapsed to ~zero
    /// size, or two controls overlapping. The NSBox "card" redesign floated its grids so controls
    /// overlapped — this assertion fails the build on exactly that class of breakage, so a broken
    /// Settings window can never ship "green" again.
    func paneLayoutIssues() -> [String] {
        guard let win = window, let content = win.contentView else { return ["settings: no window"] }
        win.setContentSize(NSSize(width: 880, height: 640))
        var issues: [String] = []
        for i in panesForTest.indices {
            selectPane(i)
            content.layoutSubtreeIfNeeded()
            let paneView = panesForTest[i].view
            let title = panesForTest[i].title
            var rects: [(String, NSRect)] = []
            func walk(_ v: NSView) {
                if v.isHidden { return }         // hidden tab sections (Summaries Mode) aren't laid out — skip
                if v is NSScroller { return }   // overlay scrollbars are chrome (0-wide when hidden, sit over content)
                if v is NSControl || v is NSTextView {
                    let f = v.frame
                    if f.width < 4 || f.height < 4 {
                        issues.append("\(title): \(type(of: v)) collapsed to \(Int(f.width))×\(Int(f.height))")
                    }
                    // NSTextView lives inside a scroll clip: its content frame is taller than the
                    // visible clip, so its "overlap" with the next row is expected, not a bug —
                    // record it for the zero-size check but not for overlap.
                    if !(v is NSTextView) { rects.append(("\(type(of: v))", v.convert(v.bounds, to: paneView))) }
                }
                if v is NSTextView { return }   // don't descend into a text view's internals
                for s in v.subviews { walk(s) }
            }
            walk(paneView)
            for a in 0..<rects.count {
                for b in (a + 1)..<rects.count {
                    let o = rects[a].1.intersection(rects[b].1)
                    if o.width > 6, o.height > 6 {
                        issues.append("\(title): \(rects[a].0) overlaps \(rects[b].0) by \(Int(o.width))×\(Int(o.height))")
                    }
                }
            }
        }
        return issues
    }

    @objc private func searchChanged() {
        visiblePaneIndexes = settingsSearchHits(query: sidebarSearch.stringValue,
                                                index: panesForTest.map { $0.searchText })
        sidebarList.reloadData()
        // Auto-select the best hit so typing alone lands on the right pane.
        if let first = visiblePaneIndexes.first {
            sidebarList.selectRowIndexes([0], byExtendingSelection: false)
            if selectedPane != first { selectPane(first) }
        }
    }

    /// Fill the "add a running app" popup with currently-running regular apps (name + bundle id).
    private func populateRunningApps() {
        addAppPopup.removeAllItems()
        addAppPopup.addItem(withTitle: "＋ Choose an app…")
        runningAppIds = [""]
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.localizedName != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for a in apps {
            addAppPopup.addItem(withTitle: "\(a.localizedName!)  (\(a.bundleIdentifier!))")
            runningAppIds.append(a.bundleIdentifier!)
        }
        addAppPopup.target = self
        addAppPopup.action = #selector(addApp)
    }

    /// Only the fields the selected mode actually uses are editable — the form reads as one choice.
    @objc private func ppModeChanged() { updatePostProcessEnabled() }
    /// Mode acts as a TAB: it SHOWS only the selected mode's settings (Automatic summary + Daily digest,
    /// or Custom command) and hides the rest — instead of greying everything out, which read as a
    /// half-built form. Off shows a one-line note.
    private func updatePostProcessEnabled() {
        let mode = PostProcessMode(rawValue: ppModeValues[max(0, ppModeSeg.selectedSegment)]) ?? .off
        setSectionGroup("pp.summary", visible: mode == .summary)
        setSectionGroup("pp.shell", visible: mode == .shell)
        setSectionGroup("pp.off", visible: mode == .off)
        promptView.isEditable = true   // shown only in summary mode now, always editable there
    }

    /// Show or hide a tagged section group (header + note + card), then relay out. The pane scrolls if
    /// the visible content overflows.
    private func setSectionGroup(_ group: String, visible: Bool) {
        for v in sectionGroupViews[group] ?? [] { v.isHidden = !visible }
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    @objc private func addApp() {
        let i = addAppPopup.indexOfSelectedItem
        guard i > 0, i < runningAppIds.count else { return }
        let bid = runningAppIds[i]
        var cur = (excludeTokens.objectValue as? [String]) ?? []
        if !cur.contains(bid) { cur.append(bid); excludeTokens.objectValue = cur }
        addAppPopup.selectItem(at: 0)
    }

    // ── Schedule pickers: select days & time ranges instead of typing them ──

    /// The "Hours" control: the range rows + an "Add time range" button beneath them.
    private func buildHoursControl() -> NSView {
        let add = NSButton(title: "  Add time range", target: self, action: #selector(addHourRange))
        add.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: "Add")
        add.imagePosition = .imageLeading
        add.bezelStyle = .inline
        add.controlSize = .small
        let v = NSStackView(views: [hoursRangesStack, add])
        v.orientation = .vertical; v.alignment = .leading; v.spacing = 8
        v.translatesAutoresizingMaskIntoConstraints = false
        hoursControlView = v
        return v
    }

    /// Days & Hours only apply when "Record only on a schedule" is ON — dim/disable them otherwise
    /// so the pane never looks like it's asking for input it will ignore.
    @objc private func scheduleToggled() { updateScheduleEnabled() }
    @objc private func calGateToggled() { updateCalGateEnabled() }
    private func updateCalGateEnabled() {
        let on = calGateBtn.state == .on
        calGatePadField.isEnabled = on
        calGatePadField.alphaValue = on ? 1 : 0.4
    }
    private func updateScheduleEnabled() {
        let on = schedBtn.state == .on
        daysSeg.isEnabled = on
        func setEnabled(_ v: NSView) {
            if let c = v as? NSControl { c.isEnabled = on }
            v.subviews.forEach(setEnabled)
        }
        if let h = hoursControlView { setEnabled(h) }
    }

    /// One time-range row: start–end pickers + a remove button. Minutes-since-midnight in, so load()
    /// can seed it and the reference date is irrelevant (only hour:minute is read back).
    private func makeHourRow(startMins: Int, endMins: Int) -> NSStackView {
        func picker(_ mins: Int) -> NSDatePicker {
            let p = NSDatePicker()
            p.datePickerStyle = .textFieldAndStepper
            p.datePickerElements = .hourMinute
            p.translatesAutoresizingMaskIntoConstraints = false
            var comps = DateComponents(); comps.year = 2000; comps.month = 1; comps.day = 1
            comps.hour = min(23, mins / 60); comps.minute = mins % 60
            p.dateValue = Calendar.current.date(from: comps) ?? p.dateValue
            return p
        }
        let dash = NSTextField(labelWithString: "–"); dash.textColor = .secondaryLabelColor
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove") ?? NSImage(),
                              target: self, action: #selector(removeHourRange(_:)))
        remove.isBordered = false
        remove.contentTintColor = .secondaryLabelColor
        let row = NSStackView(views: [picker(startMins), dash, picker(endMins), remove])
        row.orientation = .horizontal; row.spacing = 6; row.alignment = .centerY
        return row
    }

    @objc private func addHourRange() {
        hoursRangesStack.addArrangedSubview(makeHourRow(startMins: 9 * 60, endMins: 18 * 60))
        refitAfterScheduleChange()
    }

    @objc private func removeHourRange(_ sender: NSButton) {
        guard let row = sender.superview as? NSStackView else { return }
        hoursRangesStack.removeArrangedSubview(row); row.removeFromSuperview()
        refitAfterScheduleChange()
    }

    /// The Hours list grew/shrank — relay out (the pane scrolls if it now overflows).
    private func refitAfterScheduleChange() {
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// Read the day multi-select back into the parser's comma format ("mon,wed,fri"). Empty = every day.
    func serializeDays() -> String {
        daySegKeys.enumerated().filter { daysSeg.isSelected(forSegment: $0.offset) }
            .map { $0.element }.joined(separator: ",")
    }

    /// Read the time-range rows back into "HH:MM-HH:MM, …". Empty list = all hours.
    func serializeHours() -> String {
        hoursRangesStack.arrangedSubviews.compactMap { row -> String? in
            let ps = row.subviews.compactMap { $0 as? NSDatePicker }
            guard ps.count == 2 else { return nil }
            func hhmm(_ p: NSDatePicker) -> String {
                let c = Calendar.current.dateComponents([.hour, .minute], from: p.dateValue)
                return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            }
            return "\(hhmm(ps[0]))-\(hhmm(ps[1]))"
        }.joined(separator: ", ")
    }

    /// Seed the pickers from the saved pref strings (parsed via the same RecordSchedule logic the
    /// engine uses, so what you see is exactly what will record).
    func loadScheduleUI(days: String, hours: String) {
        let wd = RecordSchedule.parseDays(days)                     // 1=Sun … 7=Sat
        let keyNum = ["mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7, "sun": 1]
        for (i, k) in daySegKeys.enumerated() { daysSeg.setSelected(wd.contains(keyNum[k] ?? 0), forSegment: i) }
        hoursRangesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for r in RecordSchedule.parseRanges(hours) {
            hoursRangesStack.addArrangedSubview(makeHourRow(startMins: r.start, endMins: min(r.end, 1439)))
        }
    }

    /// Fill the "add a calendar" popup with the user's event calendars (by title). Picking one
    /// appends it to the token field; an empty token field means "use all calendars".
    /// A scrollable checkbox list of the user's event calendars (none checked = all). Keeps every
    /// calendar visible even with many entries or long names.
    /// "● Calendar name" — the calendar's own color as a leading dot, the way Calendar.app shows it.
    /// The plain `name` is what gets persisted; this only changes how the row reads.
    private func calendarCheckboxTitle(name: String, color: NSColor, font: NSFont) -> NSAttributedString {
        let side: CGFloat = 9
        let dot = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            color.setFill(); NSBezierPath(ovalIn: r).fill(); return true
        }
        let att = NSTextAttachment()
        att.image = dot
        att.bounds = NSRect(x: 0, y: (font.capHeight - side) / 2, width: side, height: side)
        let s = NSMutableAttributedString(attachment: att)
        s.append(NSAttributedString(string: "  \(name)",
                                    attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        return s
    }

    private func buildCalendarList() -> NSView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        calChecks = []
        let cals = CalendarLookup.availableCalendars()
        if cals.isEmpty {
            let l = NSTextField(labelWithString: "No calendars available (grant Calendar access, then reopen).")
            l.textColor = .secondaryLabelColor; l.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(l)
        }
        for (name, color) in cals {
            let box = NSButton(checkboxWithTitle: name, target: nil, action: nil)
            box.attributedTitle = calendarCheckboxTitle(name: name, color: color, font: box.font ?? .systemFont(ofSize: 13))
            box.setAccessibilityLabel(name)   // the attributed title leads with an image attachment
            stack.addArrangedSubview(box); calChecks.append((name, box))
        }
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        let scroll = PassthroughScrollView()   // wheel passes to the pane when the list fits
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay        // overlay + autohide: no scrollbar unless the list overflows (user)
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder   // borderless: the card is the container — no box-inside-a-box
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        // Grow to fit all calendars up to a cap, then scroll (instead of a fixed short box).
        let naturalH = CGFloat(max(1, cals.count)) * 22 + 4
        scroll.heightAnchor.constraint(equalToConstant: min(naturalH, 220)).isActive = true
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        ])
        return scroll
    }

    private func idx<T: Equatable>(_ v: T, _ arr: [T]) -> Int { arr.firstIndex(of: v) ?? 0 }

    /// The controller instance is cached by the app — RELOAD the fields from prefs on every open,
    /// or edits abandoned with Cancel linger in the form and a later Save silently persists them
    /// (confirmed review finding).
    override func showWindow(_ sender: Any?) {
        load()
        super.showWindow(sender)
    }

    private func load() {
        let c = EngineConfig.load()
        segPopup.selectItem(at: idx(Int(c.segmentSeconds), segValues))
        langPopup.selectItem(at: idx(c.whisperLang, langValues))
        transcriptLangPopup.selectItem(at: idx(TranscriptL10n.configuredCode, tLangValues))   // explicit save (even "") beats env
        modelPopup.selectItem(at: idx(Pref.str(Pref.model, "MR_WHISPER_MODEL", WhisperCatalog.defaultName), modelNames))
        customModelField.stringValue = Pref.str(Pref.customModel, "MR_MODEL_URL", "")
        // Presence, not the secret. Prefilling the real key made opening Settings an authorization prompt
        // per engine, for a value the user never asked to see.
        for (account, field) in [("deepgram", deepgramKeyField), ("openai", openaiKeyField), ("gladia", gladiaKeyField), ("elevenlabs", elevenlabsKeyField), ("deepl", deeplKeyField)] {
            field.stringValue = Keychain.exists(account) ? Self.keyMask : ""
        }
        translateProviderPopup.selectItem(at: idx(Pref.d.string(forKey: Pref.translateProvider) ?? "apple", translateProviderValues))
        openaiBaseField.stringValue = OpenAILiveTranscriber.configuredBase   // explicit save (even "") beats env
        postProcessField.stringValue = Pref.postProcessCommand               // same explicit-save semantics
        // Show the EFFECTIVE mode (incl. the v1 migration: unset mode + v1 command = Custom command) —
        // displaying Off while a hook is live would let Save silently kill it.
        ppModeSeg.selectedSegment = idx(effectivePostProcessMode(
            rawMode: Pref.explicit(Pref.postProcessMode, "MR_POST_PROCESS_MODE"),
            shellCmd: Pref.postProcessCommand).rawValue, ppModeValues)
        runnerPopup.selectItem(at: idx(Pref.explicit(Pref.summaryRunner, "MR_SUMMARY_RUNNER"), runnerValues))
        let savedPrompt = Pref.explicit(Pref.summaryPrompt, "MR_SUMMARY_PROMPT")
        promptView.string = savedPrompt.isEmpty ? defaultSummaryPrompt : savedPrompt   // show the editable default
        promptFileField.stringValue = Pref.explicit(Pref.summaryPromptFile, "MR_SUMMARY_PROMPT_FILE")
        summaryOutField.stringValue = Pref.explicit(Pref.summaryOut, "MR_SUMMARY_OUT")
        dailyBtn.state = Pref.bool(Pref.dailyDigest, "MR_DAILY_DIGEST", false) ? .on : .off
        updateBtn.state = Pref.bool(Pref.autoUpdateCheck, "MR_AUTO_UPDATE_CHECK", true) ? .on : .off
        let savedDaily = Pref.explicit(Pref.dailyPrompt, "MR_DAILY_DIGEST_PROMPT")
        dailyPromptView.string = savedDaily.isEmpty ? defaultDailyDigestPrompt : savedDaily
        dailyPromptFileField.stringValue = Pref.explicit(Pref.dailyPromptFile, "MR_DAILY_DIGEST_PROMPT_FILE")
        dailyOutField.stringValue = Pref.explicit(Pref.dailyDigestOut, "MR_DAILY_DIGEST_OUT")
        dailyNameField.stringValue = Pref.explicit(Pref.dailyDigestName, "MR_DAILY_DIGEST_NAME")
        for (engine, box) in engineSwitches { box.state = engine.isEnabled ? .on : .off }
        let hm = Pref.str(Pref.dailyDigestTime, "MR_DAILY_DIGEST_TIME", "20:00").split(separator: ":").compactMap { Int($0) }
        var tc = DateComponents(); tc.hour = hm.count == 2 ? hm[0] : 20; tc.minute = hm.count == 2 ? hm[1] : 0
        dailyTimePicker.dateValue = Calendar.current.date(from: tc) ?? Date()
        hintsTermsField.stringValue = Pref.explicit(Pref.hintsTerms, "MR_HINTS")
        hintsFileField.stringValue = Pref.explicit(Pref.hintsFile, "MR_HINTS_FILE")
        hintsCalBtn.state = Pref.bool(Pref.hintsCalendar, "MR_HINTS_CALENDAR", false) ? .on : .off
        schedBtn.state = Pref.bool(Pref.schedEnabled, "MR_SCHEDULE", false) ? .on : .off
        loadScheduleUI(days: Pref.explicit(Pref.schedDays, "MR_SCHEDULE_DAYS"),
                       hours: Pref.explicit(Pref.schedHours, "MR_SCHEDULE_HOURS"))
        updateScheduleEnabled()   // dim Days/Hours when the schedule is off
        calGateBtn.state = Pref.bool(Pref.calGated, "MR_CALENDAR_GATE", false) ? .on : .off
        calGatePadField.stringValue = String(Pref.int(Pref.calGatePad, "MR_CALENDAR_GATE_PAD", 5))
        updateCalGateEnabled()    // dim the ± minutes field when the gate is off
        // Long paths head-truncate in the field — the tooltip always carries the full value.
        for f in [dirField, audioDirField, customModelField, hintsFileField, promptFileField,
                  summaryOutField, postProcessField] {
            f.toolTip = f.stringValue.isEmpty ? nil : f.stringValue
        }
        updatePostProcessEnabled()
        voiceField.stringValue = String(Int(c.voiceMinSeconds))
        for f in [calGatePadField, voiceField] {   // reset the red-on-invalid tint to the loaded (valid) value
            f.textColor = numericFieldValid(f.stringValue) ? .labelColor : .systemRed
        }
        vadBtn.state = c.vadEnabled ? .on : .off
        systemAudioBtn.state = Pref.bool(Pref.systemAudio, "MR_SYSTEM_AUDIO", true) ? .on : .off
        echoBtn.state = Pref.bool(Pref.echoReduce, "MR_ECHO_REDUCE", false) ? .on : .off
        calBtn.state = c.useCalendarTitles ? .on : .off
        keepAudioBtn.state = c.keepAudio ? .on : .off
        audioRawCombo.stringValue = c.audioRawDays == 0 ? "Don't compress"
                                                        : AudioArchivePolicy.retentionTitle(c.audioRawDays)
        audioRetCombo.stringValue = AudioArchivePolicy.retentionTitle(c.audioRetentionDays)
        recolorRetentionCombos()
        txtRetPopup.selectItem(at: idx(c.transcriptRetentionDays, retValues))
        excludeTokens.objectValue = c.excludeBundleIds
        // Trim stored titles (older builds stored via a token field that could carry stray spaces).
        let selectedCals = Set((Pref.d.stringArray(forKey: Pref.calendars) ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) })
        for (name, box) in calChecks { box.state = selectedCals.contains(name) ? .on : .off }
        dirField.stringValue = c.transcriptsDir.path
        audioDirField.stringValue = c.audioDir.path
        // Start at login — read the live SMAppService status (never cache); locked on the dev machine.
        if #available(macOS 13, *) {
            if LoginItem.managedByLaunchAgent {
                loginBtn.state = .on; loginBtn.isEnabled = false
                loginBtn.toolTip = "Managed by the LaunchAgent on this machine."
            } else {
                switch LoginItem.status {
                case .enabled:          loginBtn.state = .on;  loginBtn.toolTip = nil
                case .requiresApproval: loginBtn.state = .on;  loginBtn.toolTip = "Pending — enable in System Settings ▸ Login Items."
                default:                loginBtn.state = .off; loginBtn.toolTip = nil   // .notRegistered / .notFound
                }
            }
        } else { loginBtn.isEnabled = false }
    }

    @objc private func chooseDir()        { choosePath(into: dirField, files: false) }
    @objc private func chooseAudioDir()   { choosePath(into: audioDirField, files: false) }
    @objc private func chooseSummaryDir() { choosePath(into: summaryOutField, files: false) }
    @objc private func chooseDailyDir()   { choosePath(into: dailyOutField, files: false) }
    // A prompt/hints file is picked in Finder like any other path.
    @objc private func choosePromptFile()      { choosePath(into: promptFileField, files: true) }
    @objc private func chooseDailyPromptFile() { choosePath(into: dailyPromptFileField, files: true) }
    @objc private func chooseHintsFile()       { choosePath(into: hintsFileField, files: true) }

    /// The one picker behind every "Choose…" button — a folder picker (`files: false`) or a file
    /// picker (`files: true`). macrec is a menu-bar (`.accessory`) app, so a bare
    /// `NSOpenPanel.runModal()` can open behind everything or never take key focus — the "Choose…"
    /// button then looked dead (user report: Storage "Choose…" did nothing). Presenting the panel as a
    /// SHEET on the Settings window makes it always surface and stay tied to the window; we fall back
    /// to activate-then-runModal only if the window is somehow absent. Seeds at the field's current path.
    private func choosePath(into field: NSTextField, files: Bool) {
        let p = NSOpenPanel()
        p.canChooseDirectories = !files
        p.canChooseFiles = files
        p.allowsMultipleSelection = false
        p.canCreateDirectories = !files
        let cur = (field.stringValue as NSString).expandingTildeInPath
        if !field.stringValue.isEmpty {
            // A file field seeds the panel at its enclosing DIRECTORY, with the current file's name in
            // the name field so it's selected rather than hunted for; handing NSOpenPanel a file path as
            // `directoryURL` opens the user's home instead.
            p.directoryURL = files ? URL(fileURLWithPath: cur).deletingLastPathComponent()
                                   : URL(fileURLWithPath: cur)
            if files { p.nameFieldStringValue = URL(fileURLWithPath: cur).lastPathComponent }
        }
        let apply: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let u = p.url else { return }
            field.stringValue = u.path
            field.toolTip = u.path   // fields head-truncate; the tooltip must track the new value (load() sets it once)
        }
        // Present as a sheet on a VISIBLE window; only fall back to runModal when there's none to host
        // one (headless selftest/snapshot) — a bare runModal on this .accessory app opens behind.
        if dirPickerPresentation(hasVisibleWindow: window?.isVisible == true) == .sheet, let win = window {
            p.beginSheetModal(for: win, completionHandler: apply)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            apply(p.runModal())
        }
    }

    /// Every "Choose…" button in the built panes (folder AND file pickers) is bound to a handler this
    /// controller actually implements — a headless guard against a picker button silently wired to
    /// nothing / a renamed selector. NOTE: this does NOT prove the panel surfaces (the real bug) — the
    /// sheet-vs-runModal decision is tested via dirPickerPresentation, and actual surfacing by
    /// manually driving Settings.
    /// Switches whose name lives in a sibling label and who therefore announce nothing to VoiceOver.
    /// Replacing the old `NSButton(checkboxWithTitle:)` rows silently dropped every label.
    var unlabeledSwitchesForTest: Int {
        var n = 0
        func walk(_ v: NSView) {
            if v is NSSwitch, v.accessibilityLabel()?.isEmpty ?? true { n += 1 }
            v.subviews.forEach(walk)
        }
        for p in panesForTest { walk(p.view) }
        return n
    }

    var chooseButtonsWiredForTest: (count: Int, allWired: Bool) {
        var btns: [NSButton] = []
        func walk(_ v: NSView) { if let b = v as? NSButton, b.title == "Choose…" { btns.append(b) }; v.subviews.forEach(walk) }
        for p in panesForTest { walk(p.view) }
        let allWired = btns.allSatisfy { b in
            guard let action = b.action, let target = b.target as? NSObject else { return false }
            return target.responds(to: action)
        }
        return (btns.count, allWired)
    }

    /// Visible confirmation that a Save landed, now that Save no longer closes the window. Re-saving
    /// restarts the fade rather than letting the first timer hide the label mid-flash.
    /// `cancel()` can't reach a fade that already started, so a generation counter fences its completion.
    private func flashSaved() {
        savedFlash?.cancel()
        flashGen &+= 1
        let gen = flashGen
        savedLabel.isHidden = false
        savedLabel.alphaValue = 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.flashGen else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; self.savedLabel.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in
                guard let self, gen == self.flashGen else { return }
                self.savedLabel.isHidden = true
            })
        }
        savedFlash = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    /// Shown in a key field when a credential is stored. Never a real key, and never saved back.
    static let keyMask = "••••••••••••"

    func loadForTest() { load() }
    var keyFieldsForTest: [String] { [deepgramKeyField, openaiKeyField, gladiaKeyField, elevenlabsKeyField, deeplKeyField].map(\.stringValue) }
    /// Test hook: the tint controlTextDidChange actually applies to a numeric field for `input`.
    func numericTintForTest(_ input: String) -> NSColor {
        calGatePadField.stringValue = input
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: calGatePadField))
        return calGatePadField.textColor ?? .labelColor
    }

    /// Every pref the recorder reads. Missing one means Save saves it and nothing happens.
    private static let engineKeys = [
        Pref.segment, Pref.lang, Pref.transcriptLang, Pref.model, Pref.customModel, Pref.exclude,
        Pref.txtDir, Pref.audioDir, Pref.keepAudio, Pref.vad, Pref.systemAudio, Pref.echoReduce,
        Pref.cal, Pref.calendars, Pref.voiceMin, Pref.hintsTerms, Pref.hintsFile, Pref.hintsCalendar,
        Pref.audioRawDays, Pref.audioRetention, Pref.txtRetention,
        // The schedule belongs here: `restartEngine()` is what clears `schedulePaused` and re-baselines
        // the schedule, so leaving these out meant switching "Record only on a schedule" OFF saved the
        // pref and left the engine parked off-hours, with no way to get recording back from Settings.
        Pref.schedEnabled, Pref.schedDays, Pref.schedHours,
        // Calendar-gate too: toggling "record only during meetings" must re-evaluate the window on Save
        // (else it parks/records with no meeting until the next 30 s tick) — same reason as the schedule.
        Pref.calGated, Pref.calGatePad,
    ]
    /// A switch turned on for an engine with no key silently did nothing: the engine just never appeared
    /// in the overlay's picker. Say so at the moment the user saves it.
    private func warnAboutEnginesMissingCredentials() {
        let selectedProvider = TranslationProvider(rawValue: Pref.d.string(forKey: Pref.translateProvider) ?? "") ?? .apple
        let missing = missingCredentialLabels(engines: LiveEngine.allCases,
                                              engineEnabled: { $0.isEnabled }, engineReady: { $0.isReady },
                                              translationProvider: selectedProvider, deeplReady: TranslationProvider.deepl.isReady)
        guard !missing.isEmpty else { return }
        let names = missing.joined(separator: ", ")
        let a = NSAlert()
        a.messageText = missing.count == 1 ? "\(names) has no API key" : "Some features have no API key"
        a.informativeText = "Without a key, \(names) can't run — captions fall back to Apple. "
            + "Everything else was saved."
        a.alertStyle = .warning
        if dirPickerPresentation(hasVisibleWindow: window?.isVisible == true) == .sheet, let win = window {
            a.beginSheetModal(for: win, completionHandler: nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    static var engineKeysForTest: [String] { engineKeys }
    private func engineSettingsDigest() -> String {
        engineFingerprint(Dictionary(uniqueKeysWithValues: Self.engineKeys.map {
            ($0, Pref.d.object(forKey: $0).map { String(describing: $0) } ?? "∅")
        }))
    }

    @objc private func saveSettings() {
        let engineBefore = engineSettingsDigest()
        // Keychain first — if a credential write fails, abort BEFORE touching any other setting so
        // the user isn't left with a half-saved state (and no key is silently lost). All-or-nothing:
        // keys saved earlier in the loop are rolled back (best effort) on a later failure.
        // Only credentials the user actually edited are touched. A field still showing the mask means
        // "unchanged", so Save never reads or rewrites a key it wasn't given — and never asks the user
        // to authorize handing the old one back just to save an unrelated setting.
        let creds = [("deepgram", deepgramKeyField, "Deepgram"), ("openai", openaiKeyField, "OpenAI"),
                     ("gladia", gladiaKeyField, "Gladia"), ("elevenlabs", elevenlabsKeyField, "ElevenLabs"),
                     ("deepl", deeplKeyField, "DeepL")]
            .filter { $0.1.stringValue != Self.keyMask }
        let previousKeys = creds.map { ($0.0, Keychain.get($0.0) ?? "") }
        for (i, cred) in creds.enumerated() {
            let (account, field, name) = cred
            if Keychain.set(account, field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) { continue }
            for (acct, old) in previousKeys[..<i] { Keychain.set(acct, old) }   // best-effort rollback
            let a = NSAlert()
            a.messageText = "Couldn't save the \(name) API key"
            a.informativeText = "The Keychain write failed (see the log). Settings were not applied — try saving again."
            a.alertStyle = .warning
            a.runModal()
            return   // keep Settings open
        }
        let d = Pref.d
        d.set(Double(segValues[max(0, segPopup.indexOfSelectedItem)]), forKey: Pref.segment)
        d.set(langValues[max(0, langPopup.indexOfSelectedItem)], forKey: Pref.lang)
        d.set(tLangValues[max(0, transcriptLangPopup.indexOfSelectedItem)], forKey: Pref.transcriptLang)
        d.set(modelNames[max(0, modelPopup.indexOfSelectedItem)], forKey: Pref.model)
        d.set(customModelField.stringValue.trimmingCharacters(in: .whitespaces), forKey: Pref.customModel)
        d.set(openaiBaseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.openaiBase)
        d.set(translateProviderValues[max(0, translateProviderPopup.indexOfSelectedItem)], forKey: Pref.translateProvider)
        d.set(postProcessField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.postProcessCmd)
        d.set(ppModeValues[max(0, ppModeSeg.selectedSegment)], forKey: Pref.postProcessMode)
        d.set(runnerValues[max(0, runnerPopup.indexOfSelectedItem)], forKey: Pref.summaryRunner)
        d.set(promptView.string.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.summaryPrompt)
        d.set(promptFileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.summaryPromptFile)
        d.set(summaryOutField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.summaryOut)
        d.set(dailyBtn.state == .on, forKey: Pref.dailyDigest)
        d.set(updateBtn.state == .on, forKey: Pref.autoUpdateCheck)
        let dp = dailyPromptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        d.set(dp == defaultDailyDigestPrompt ? "" : dp, forKey: Pref.dailyPrompt)   // default stays editable, not stored
        d.set(dailyPromptFileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.dailyPromptFile)
        d.set(dailyOutField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.dailyDigestOut)
        d.set(dailyNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.dailyDigestName)
        // Persist the ON list: a cloud engine we add later must not become enabled behind the user's back.
        d.set(engineSwitches.filter { $0.box.state == .on }.map { $0.engine.rawValue }, forKey: Pref.liveEnginesOn)
        let tc = Calendar.current.dateComponents([.hour, .minute], from: dailyTimePicker.dateValue)
        d.set(String(format: "%02d:%02d", tc.hour ?? 20, tc.minute ?? 0), forKey: Pref.dailyDigestTime)
        d.set(hintsTermsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.hintsTerms)
        d.set(hintsFileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Pref.hintsFile)
        d.set(hintsCalBtn.state == .on, forKey: Pref.hintsCalendar)
        d.set(schedBtn.state == .on, forKey: Pref.schedEnabled)
        d.set(serializeDays(), forKey: Pref.schedDays)
        d.set(serializeHours(), forKey: Pref.schedHours)
        d.set(calGateBtn.state == .on, forKey: Pref.calGated)
        // Ignored on save when INVALID (red) — keep the previously-saved value; empty → the default.
        // numericFieldValid already rejects negatives, so no coercion to 0 and no persisting a "-1".
        if numericFieldValid(calGatePadField.stringValue) {
            d.set(min(Int(calGatePadField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 5, 1440), forKey: Pref.calGatePad)
        }
        if numericFieldValid(voiceField.stringValue) {
            d.set(Double(Int(voiceField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 5), forKey: Pref.voiceMin)
        }
        d.set(vadBtn.state == .on, forKey: Pref.vad)
        d.set(systemAudioBtn.state == .on, forKey: Pref.systemAudio)
        d.set(echoBtn.state == .on, forKey: Pref.echoReduce)
        d.set(calBtn.state == .on, forKey: Pref.cal)
        d.set(keepAudioBtn.state == .on, forKey: Pref.keepAudio)
        // Unparseable combo text (shown red) keeps the previously saved period instead of guessing.
        if let v = AudioArchivePolicy.parseRetentionDays(audioRawCombo.stringValue) { d.set(v, forKey: Pref.audioRawDays) }
        if let v = AudioArchivePolicy.parseRetentionDays(audioRetCombo.stringValue) { d.set(v, forKey: Pref.audioRetention) }
        d.set(retValues[max(0, txtRetPopup.indexOfSelectedItem)], forKey: Pref.txtRetention)
        let ids = (excludeTokens.objectValue as? [String]) ?? []
        d.set(ids.joined(separator: " "), forKey: Pref.exclude)
        // Only persist if we actually listed calendars — otherwise (no Calendar access → empty list)
        // we'd silently wipe a previously-saved selection.
        if !calChecks.isEmpty {
            d.set(calChecks.filter { $0.box.state == .on }.map { $0.name }, forKey: Pref.calendars)
        }
        d.set(dirField.stringValue, forKey: Pref.txtDir)
        d.set(audioDirField.stringValue, forKey: Pref.audioDir)
        // Apply "Start at login" (skip on the dev machine where the LaunchAgent owns autostart).
        if #available(macOS 13, *), !LoginItem.managedByLaunchAgent {
            if LoginItem.setEnabled(loginBtn.state == .on) == .requiresApproval { LoginItem.openSettings() }
        }
        // A rotated DeepL key must reach the running overlay even if provider/target didn't change.
        if #available(macOS 26, *) { LiveCaptions.shared.settingsSaved(translationCredsChanged: creds.contains { $0.0 == "deepl" }) }
        warnAboutEnginesMissingCredentials()
        // `stop()` discards the in-progress segment, and Return in any field now fires Save.
        if engineSettingsDigest() != engineBefore { onSave() }
        flashSaved()
    }
    @objc private func closeOnly() { window?.close() }
}

// MARK: - login-item autostart (SMAppService)

/// Auto-start at login via the modern Login Item API (macOS 13+). Works for our self-signed,
/// /Applications-installed app because the signature is a stable cert-based DR. On the developer's
/// machine the install.sh LaunchAgent owns autostart, so we detect it and stay out of the way.

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { visiblePaneIndexes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let p = panesForTest[visiblePaneIndexes[row]]
        let cell = SidebarCell()
        // Monochrome SF Symbol + label — a clean nav column. SidebarCell tints the icon white when
        // the row is selected (accent fill); muted secondary otherwise.
        let icon = NSImageView(image: NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.title) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: p.title)
        label.font = .systemFont(ofSize: 13)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.imageView = icon      // outlet wiring lets the source-list style manage selection colors
        cell.textField = label
        cell.addSubview(icon); cell.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
        ])
        return cell
    }

    /// Keeps the selected pane accent-filled regardless of where keyboard focus sits — see SidebarRowView.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SidebarRowView() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebarList.selectedRow
        guard row >= 0, visiblePaneIndexes.indices.contains(row) else { return }
        selectPane(visiblePaneIndexes[row])
    }
}
