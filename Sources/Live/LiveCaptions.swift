import AppKit
import AVFoundation
import Foundation
import Speech
import Translation

/// Which speakers to transcribe for the live overlay. Each source runs its own on-device analyzer,
/// so transcribing one instead of two roughly halves inference load → lower latency. Default is
/// `.other` (the remote party / system audio): you already know what you said, and it's the cheaper
/// path. (The saved whisper transcript always covers everyone regardless of this setting.)
enum LiveSource: String {
    case both, other, me
    static var current: LiveSource { LiveSource(rawValue: Pref.d.string(forKey: Pref.liveSource) ?? "") ?? .other }
}

/// Option lists for the live-caption overlay's control bar. These settings live on the overlay itself
/// (not the Settings window) so changes apply immediately. Index 0 of each is the default. Language
/// names are endonyms (each language's own name for itself) for quick recognition; translation is prefixed with →.
enum LiveCaptionOptions {
    static let langValues   = ["", "ko", "ja", "en", "zh-Hans", "es", "fr", "de"]
    static let langTitles   = ["System", "한국어", "日本語", "English", "中文", "Español", "Français", "Deutsch"]
    static let sourceValues = ["other", "both", "me"]
    static let sourceTitles = ["Them", "Both", "Me"]
    static let transValues  = ["", "ko", "ja", "en", "zh-Hans", "es", "fr", "de"]
    static let transTitles  = ["Off", "→한국어", "→日本語", "→English", "→中文", "→Español", "→Français", "→Deutsch"]
}

/// Owns the two per-source transcribers + optional translator + the floating caption window.
@available(macOS 26, *)
final class LiveCaptions {
    static let shared = LiveCaptions()
    // mic/sys are written on the main thread (start/stop) and read on the audio queue (feed*), so a
    // lock guards the reference swap. LiveTranscriber.feed is itself thread-safe.
    private let srcLock = NSLock()
    private let feedQueue = DispatchQueue(label: "macrec.live.feed", qos: .userInitiated)
    private var mic: (any LiveTranscribing)?
    private var sys: (any LiveTranscribing)?
    private var translator: (any LiveTranslating)?   // nil = no live translation
    private var window: LiveCaptionWindow?
    struct CapLine {
        var speaker: String
        var text: String
        var final: Bool
        var time: Date                      // creation time — doubles as the line's identity
        var transParts: [String?] = []      // per-sentence translations, positional (async-safe)
        var transRequested = 0              // how many complete sentences have been sent to translate
        var transFinal = false              // the authoritative full-text translation has landed
        var transTail: String?              // live translation of the UNFINISHED tail (volatile)
        var tailInFlight = false            // ONE tail request at a time — landing refires with the newest tail
        var tailLastSent = ""               // tail text of the in-flight/last request (skip if unchanged)
        var tailSentAt: Double = 0          // floor between back-to-back refires
        var translated: String? {
            // IN-ORDER prefix only: sentence translations land async, and rendering part 2 while
            // part 1 is still in flight would show the translation out of order. The tail always
            // renders last (it is by definition the newest region).
            var parts: [String] = []
            for p in transParts { guard let p else { break }; parts.append(p) }
            if let t = transTail { parts.append(t) }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }
    private var lines: [CapLine] = []
    private var mineLabel = ""   // label used for the mic track (for speaker coloring)
    private var showLabels = true   // false in single-speaker modes (one voice → the label is redundant)
    // Last-applied live config — so reconfigure() can no-op on unchanged values and avoid needless
    // analyzer rebuilds (each rebuild re-pays the ~model warm-up).
    private var curLocaleId = "", curEngine = "", curSource = "", curTranslateId = "", curTranslateProvider = ""
    private var engineGen = 0   // bumped on translator rebuild; a translate Task from an older gen is ignored
    private let maxLines = 12
    private(set) var active = false

    /// Menu toggle (main thread).
    func toggle() { if active { stop() } else { start() } }

    /// Settings were saved: the engine picker and the engine itself must reflect them without the user
    /// closing and reopening the overlay (an engine switched off stayed in the menu until then).
    /// `translationCredsChanged` = the DeepL key was edited; force a translator rebuild so the running
    /// overlay picks up the new key even when the provider/target didn't change.
    func settingsSaved(translationCredsChanged: Bool = false) {
        guard active else { return }
        window?.reloadEngineChoices()
        reconfigure(force: translationCredsChanged)
    }

    func start() {
        guard !active else { return }
        active = true; lines = []; renderScheduled = false   // clear any coalescing state left by a prior session
        let win = LiveCaptionWindow(
            onClose: { [weak self] in self?.stop() },
            onReconfigure: { [weak self] in self?.reconfigure() },   // language / source / translate changed
            onRestyle: { [weak self] in self?.render() })            // text size / timestamps changed
        window = win; win.show()
        buildEngine()
        elog("live: captions ON")
    }

    private typealias LiveCfg = (locale: Locale, engine: LiveEngine, source: LiveSource, translateId: String)

    /// Snapshot the current live prefs.
    private func liveConfig() -> LiveCfg {
        let capId = Pref.d.string(forKey: Pref.captionLang) ?? ""   // "" = system
        let locale = capId.isEmpty ? Locale.current : Locale(identifier: capId)
        return (locale, LiveEngine.current, LiveSource.current, Pref.d.string(forKey: Pref.translateTo) ?? "")
    }

    /// Reports the resolved language into the overlay title.
    private func makeOnLocale() -> (Locale) -> Void {
        { [weak self] loc in
            let name = Locale.current.localizedString(forLanguageCode: loc.language.languageCode?.identifier ?? "")
                ?? loc.identifier(.bcp47)
            DispatchQueue.main.async { self?.window?.setLanguage(name) }
        }
    }

    /// (Re)build the translator (nil = off, or target == caption language). Provider comes from prefs;
    /// DeepL falls back to Apple if its key vanished between the readiness check and here.
    private func rebuildTranslator(_ cfg: LiveCfg) {
        engineGen &+= 1   // invalidate any in-flight translate Task started against the previous translator
        translator = nil
        guard !cfg.translateId.isEmpty,
              Locale(identifier: cfg.translateId).language.languageCode?.identifier != cfg.locale.language.languageCode?.identifier
        else { return }
        let target = Locale.Language(identifier: cfg.translateId)
        if TranslationProvider.current == .deepl, let dl = DeepLTranslator(target: target) {
            translator = dl; elog("live: translator = DeepL (target=\(cfg.translateId))"); return
        }
        translator = LiveTranslator(source: cfg.locale.language, target: target)
    }

    /// Full build of the transcriber(s) + translator from current prefs (warms up the analyzer). Serves
    /// both the first start and a locale/engine/source change; the window is reused across all of them.
    private func buildEngine() {
        let cfg = liveConfig()
        window?.setPreparing()   // title shows "starting…" until the analyzer warms up (onLocale replaces it)
        let (mine, theirs) = speakerLabels(forLanguage: cfg.locale.language.languageCode?.identifier)
        mineLabel = mine
        // A single speaker needs no label, so hide it (render then uses a neutral color).
        showLabels = (cfg.source == .both)
        rebuildTranslator(cfg)
        let onLocale = makeOnLocale()
        var m: (any LiveTranscribing)?, s: (any LiveTranscribing)?
        if cfg.source == .both || cfg.source == .me {
            m = makeTranscriber(label: mine, locale: cfg.locale, onLocale: onLocale) { [weak self] t, f in self?.post(mine, t, f) }
        }
        if cfg.source == .both || cfg.source == .other {
            s = makeTranscriber(label: theirs, locale: cfg.locale, onLocale: m == nil ? onLocale : nil) { [weak self] t, f in self?.post(theirs, t, f) }
        }
        srcLock.lock(); mic = m; sys = s; srcLock.unlock()
        m?.start(); s?.start()
        curLocaleId = cfg.locale.identifier; curEngine = cfg.engine.rawValue
        curSource = cfg.source.rawValue; curTranslateId = cfg.translateId; curTranslateProvider = TranslationProvider.current.rawValue
        elog("live: engine built (engine=\(cfg.engine.rawValue), locale=\(cfg.locale.identifier), source=\(cfg.source.rawValue), translate=\(cfg.translateId.isEmpty ? "off" : cfg.translateId))")
    }

    /// Build the configured engine for one source. Extensible: add a LiveEngine case + a branch here.
    private func makeTranscriber(label: String, locale: Locale, onLocale: ((Locale) -> Void)?,
                                 onUpdate: @escaping (String, Bool) -> Void) -> any LiveTranscribing {
        switch LiveEngine.current {
        case .whisper:  return WhisperLiveTranscriber(label: label, locale: locale, onLocale: onLocale, onUpdate: onUpdate)
        case .deepgram: return DeepgramLiveTranscriber(label: label, locale: locale, onLocale: onLocale, onUpdate: onUpdate)
        case .openai:   return OpenAILiveTranscriber(label: label, locale: locale, onLocale: onLocale, onUpdate: onUpdate)
        case .gladia:   return GladiaLiveTranscriber(label: label, locale: locale, onLocale: onLocale, onUpdate: onUpdate)
        case .elevenlabs: return ElevenLabsLiveTranscriber(label: label, locale: locale, onLocale: onLocale, onUpdate: onUpdate)
        case .apple:    return LiveTranscriber(label: label, locale: locale, onLocale: onLocale, onUpdate: onUpdate)
        }
    }

    /// Apply an overlay control-bar change. Keeps the transcript history; only rebuilds the analyzer
    /// (which re-warms) when the locale/engine/source actually changed. Re-picking the active value is a
    /// no-op, and a translate-only change swaps just the translator (instant, no warm-up).
    /// `force` rebuilds the translator even when provider/target look unchanged — a Settings Save may
    /// have rotated the DeepL API key, which the value comparison can't see (and re-reading the key to
    /// compare would risk a Keychain prompt). Save is infrequent, so an unconditional translator rebuild
    /// is cheap; without it, fixing a bad key in Settings never reached the running overlay.
    private func reconfigure(force: Bool = false) {
        guard active else { return }
        let cfg = liveConfig()
        let sameSources = cfg.locale.identifier == curLocaleId && cfg.engine.rawValue == curEngine && cfg.source.rawValue == curSource
        let sameTranslate = !liveTranslatorNeedsRebuild(oldTarget: curTranslateId, newTarget: cfg.translateId,
                                                        oldProvider: curTranslateProvider, newProvider: TranslationProvider.current.rawValue)
        if !force && sameSources && sameTranslate { return }   // nothing changed (e.g. re-picked the active language)
        // Keep the transcript history on every change — the overlay filters what it SHOWS by source
        // (Both→Me hides the other party's lines; switching back to Both reveals them again).
        for i in lines.indices where !lines[i].final { lines[i].final = true }
        // Caption language changed → remap kept lines' speaker labels so their label/color stay correct.
        let (oldMine, oldTheirs) = speakerLabels(forLanguage: Locale(identifier: curLocaleId).language.languageCode?.identifier)
        let (newMine, newTheirs) = speakerLabels(forLanguage: cfg.locale.language.languageCode?.identifier)
        if oldMine != newMine || oldTheirs != newTheirs {
            for i in lines.indices {
                if lines[i].speaker == oldMine { lines[i].speaker = newMine }
                else if lines[i].speaker == oldTheirs { lines[i].speaker = newTheirs }
            }
        }
        if !sameSources {
            srcLock.lock(); let m = mic, s = sys; mic = nil; sys = nil; srcLock.unlock()
            m?.stop(); s?.stop()
            buildEngine()   // rebuild (warms up); the existing captions stay on screen
            elog("live: reconfigured (rebuild)")
        } else {
            rebuildTranslator(cfg); curTranslateId = cfg.translateId; curTranslateProvider = TranslationProvider.current.rawValue   // translate-only → instant
            elog("live: reconfigured (translator only)")
        }
        renderScheduled = false; render()
    }

    func stop() {
        guard active else { return }
        active = false; renderScheduled = false   // drop any pending coalesced render (so a restart isn't suppressed)
        srcLock.lock(); let m = mic, s = sys; mic = nil; sys = nil; srcLock.unlock()
        m?.stop(); s?.stop()
        translator = nil
        let w = window; window = nil; w?.close()
        elog("live: captions OFF")
    }

    // Audio-queue feeds (no-op when inactive). Snapshot the ref under the lock, then feed outside it.
    // Feeds arrive on the capture threads (the tap's real-time IOProc for system audio!). Hop onto a
    // normal queue so the format conversion never runs on the real-time audio thread (avoids glitches).
    func feedMic(_ b: AVAudioPCMBuffer) { srcLock.lock(); let m = mic; srcLock.unlock(); if let m { feedQueue.async { m.feed(b) } } }
    func feedSystem(_ b: AVAudioPCMBuffer) { srcLock.lock(); let s = sys; srcLock.unlock(); if let s { feedQueue.async { s.feed(b) } } }

    private func post(_ speaker: String, _ text: String, _ final: Bool) {
        DispatchQueue.main.async { [weak self] in self?.apply(speaker, text, final) }
    }
    private func apply(_ speaker: String, _ text: String, _ final: Bool) {
        guard active else { return }
        // Transcript-level echo suppression (belt to the AEC's braces): a mic line whose text is a
        // (garbled) copy of a recent far-end line is the speakers leaking back in, not the user.
        if speaker == mineLabel, EchoCanceller.shared.enabled {
            let cutoff = Date().addingTimeInterval(-10)
            let isEcho = lines.contains { $0.speaker != mineLabel && $0.time > cutoff
                                          && isLikelyEcho(mine: text, theirs: $0.text) }
            if isEcho {
                // Drop it — and if this was updating an in-progress mine line that just BECAME an
                // echo (the garbled copy streams in over a few updates), remove that line too.
                if let i = lines.lastIndex(where: { $0.speaker == speaker && !$0.final }) {
                    lines.remove(at: i)
                    render()
                }
                return
            }
        }
        // Engines often emit partials with a leading space — trim so lines never render indented.
        let text = text.trimmingCharacters(in: .whitespaces)
        // Update this speaker's in-progress (non-final) line, or start a new one.
        let i: Int
        if let j = lines.lastIndex(where: { $0.speaker == speaker && !$0.final }) {
            lines[j].text = text; lines[j].final = final
            i = j
        } else {
            lines.append(CapLine(speaker: speaker, text: text, final: final, time: Date()))
            i = lines.count - 1
        }
        let removed = max(0, lines.count - maxLines)
        if removed > 0 { lines.removeFirst(removed) }
        render()
        // Sentence-streamed translation: translate each sentence THE MOMENT it completes inside the
        // growing partial (punctuation boundary) — timely, and the translation line only ever
        // APPENDS whole sentences, so it never rewrites under the reader (the old partial-retranslate
        // made both lines move at once; the finals-only attempt landed seconds late — user reports).
        // Finalization then re-translates the full text ONCE as the authoritative version.
        translateNewSentences(at: i - removed, final: final)
    }

    private func translateNewSentences(at index: Int, final: Bool) {
        guard let translator, lines.indices.contains(index) else { return }
        let line = lines[index]
        guard !line.text.isEmpty, !line.transFinal else { return }
        let gen = engineGen
        let lineTime = line.time
        if final {
            lines[index].transFinal = true
            // The streamed translation (confirmed sentences + last tail) is already on screen.
            // Re-translating the FULL text here was the longest possible request on a session
            // that serializes — the NEXT line's first tail queued behind it ("second line is
            // slow" — user report). Promote what's shown instead; only lines that never got any
            // streaming translation (e.g. translation just switched on) still pay a full pass.
            if lines[index].translated != nil {
                if let tail = lines[index].transTail {
                    lines[index].transParts.append(tail)   // freeze the volatile tail as the last part
                    lines[index].transTail = nil
                }
                return
            }
            let full = line.text
            Task { [weak self] in
                guard let out = await translator.translate(full) else { return }
                await MainActor.run {
                    guard let self, self.engineGen == gen,
                          let k = self.lines.lastIndex(where: { $0.time == lineTime }) else { return }
                    self.lines[k].transParts = [out]   // authoritative full pass (had nothing streamed)
                    self.lines[k].transTail = nil
                    self.render()
                }
            }
            return
        }
        let complete = completeSentences(line.text)
        if complete.count > line.transRequested {
            for idx in line.transRequested..<complete.count {
                let sentence = complete[idx]
                Task { [weak self] in
                    guard let out = await translator.translate(sentence) else { return }
                    await MainActor.run {
                        guard let self, self.engineGen == gen,
                              let k = self.lines.lastIndex(where: { $0.time == lineTime }),
                              !self.lines[k].transFinal else { return }
                        while self.lines[k].transParts.count <= idx { self.lines[k].transParts.append(nil) }
                        self.lines[k].transParts[idx] = out
                        self.render()
                    }
                }
            }
            lines[index].transRequested = complete.count
        }
        // Live tail — SELF-CLOCKING: exactly one request in flight; the moment a result lands it
        // refires with the newest tail if it moved. Latency = the model's own speed (~0.2-0.4 s),
        // not a timer (the old 0.5 s throttle read as "not real-time" — user report). A small
        // 0.15 s floor stops single-keystroke hammering.
        let tail = currentTail(of: line.text, complete: complete)
        if tail.isEmpty, lines[index].transTail != nil, complete.count == lines[index].transRequested {
            lines[index].transTail = nil   // tail fully consumed into confirmed sentences
        }
        fireTailTranslation(lineTime: lineTime, gen: gen)
    }

    /// The words after the last completed sentence — the volatile region live translation chases.
    private func currentTail(of text: String, complete: [String]) -> String {
        if let last = complete.last, let r = text.range(of: last, options: .backwards) {
            return String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return complete.isEmpty ? text : ""
    }

    private func fireTailTranslation(lineTime: Date, gen: Int) {
        guard let translator, engineGen == gen,
              let k = lines.lastIndex(where: { $0.time == lineTime }) else { return }
        let tail = currentTail(of: lines[k].text, complete: completeSentences(lines[k].text))
        guard shouldFireTailTranslation(tail: tail, lastSent: lines[k].tailLastSent,
                                        inFlight: lines[k].tailInFlight, final: lines[k].transFinal) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let wait = max(0, 0.15 - (now - lines[k].tailSentAt))
        lines[k].tailInFlight = true
        lines[k].tailLastSent = tail
        lines[k].tailSentAt = now + wait
        Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            let out = await translator.translate(tail)
            await MainActor.run {
                guard let self, self.engineGen == gen else { return }
                guard let k = self.lines.lastIndex(where: { $0.time == lineTime }) else { return }
                self.lines[k].tailInFlight = false
                if !self.lines[k].transFinal, let out {
                    self.lines[k].transTail = out
                    self.render()
                }
                self.fireTailTranslation(lineTime: lineTime, gen: gen)   // tail moved meanwhile? chase it
            }
        }
    }
    // Volatile results arrive many times/sec from BOTH transcribers; rebuilding the whole overlay
    // each time churns the UI thread. Coalesce to ~10 fps (negligible vs the engine's own latency).
    private var renderScheduled = false
    private func render() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            guard self.active else { return }
            let showTS = Pref.bool(Pref.liveTimestamps, "MR_LIVE_TIMESTAMPS", true)
            let fontSize = CGFloat(Pref.dbl(Pref.liveFontSize, "MR_LIVE_FONT_SIZE", 14))
            // Show only the lines matching the current source (Both = all; Me = mine; Them = the rest).
            let mode = LiveSource(rawValue: self.curSource) ?? .both
            let visible = self.lines.filter { l in
                switch mode {
                case .both:  return true
                case .me:    return l.speaker == self.mineLabel
                case .other: return l.speaker != self.mineLabel
                }
            }
            self.window?.render(visible.map { (speaker: $0.speaker, text: $0.text, translated: $0.translated,
                                        time: $0.time, mine: $0.speaker == self.mineLabel, inProgress: !$0.final) },
                                showTimestamps: showTS, fontSize: fontSize, showLabels: self.showLabels)
        }
    }
}

/// The overlay's opacity slider moves the BACKDROP only, never the captions. Fading the whole window
/// (`panel.alphaValue`) fades its children too, so at the low end the very text the overlay exists to
/// show disappeared along with the background. The range bottoms out at ZERO — a fully transparent
/// backdrop is the closed-caption look, captions floating over whatever is behind them — which is safe
/// precisely because the text keeps its own contrast (see the halo in `render`). Pure + selftested.
let captionOpacityRange: ClosedRange<Double> = 0.0...1.0
