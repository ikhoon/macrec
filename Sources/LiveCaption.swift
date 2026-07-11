// Live captions: the on-device and cloud transcription engines, the translator, and the floating
// overlay they feed. Saved transcripts come from whisper-cli on segment rotation — this is an
// ephemeral view, and everything here is gated on macOS 26.

import AppKit
import AVFoundation
import Foundation
import Speech
import Translation

// MARK: - live transcription (macOS 26 SpeechAnalyzer → real-time caption overlay)
//
// Tees the same canon (16 kHz mono) audio the recorder writes into an on-device SpeechAnalyzer per
// source (mic → "me", system → "them") for low-latency live captions in a floating panel. whisper-cli on
// segment rotation stays the authoritative, saved transcript — this overlay is an ephemeral view.

@available(macOS 26, *)
final class LiveTranscriber: LiveTranscribing {
    private let label: String
    private let locale: Locale
    private let onUpdate: (String, Bool) -> Void   // (text, isFinal)
    private let onLocale: ((Locale) -> Void)?      // reports the resolved speech locale once ready
    private let lock = NSLock()
    private var cont: AsyncStream<AnalyzerInput>.Continuation?
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var task: Task<Void, Never>?

    init(label: String, locale: Locale, onLocale: ((Locale) -> Void)? = nil,
         onUpdate: @escaping (String, Bool) -> Void) {
        self.label = label; self.locale = locale; self.onLocale = onLocale; self.onUpdate = onUpdate
    }

    func start() { task = Task { [weak self] in
        do { try await self?.run() } catch { elog("live[\(self?.label ?? "?")]: transcriber failed: \(error)") } } }

    private func run() async throws {
        // Locale.current can be a region SpeechTranscriber doesn't support (e.g. en_KR → error 15
        // "unsupported locale"). Map it to a supported (ideally already-installed) locale.
        let t0 = ProcessInfo.processInfo.systemUptime
        guard let (loc, isInstalled) = await Self.resolvedLocale(locale) else {
            elog("live[\(label)]: no supported speech locale for \(locale.identifier)"); return
        }
        if loc.identifier(.bcp47) != locale.identifier(.bcp47) {
            elog("live[\(label)]: locale \(locale.identifier) → \(loc.identifier(.bcp47))")
        }
        let transcriber = SpeechTranscriber(locale: loc, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        let t1 = ProcessInfo.processInfo.systemUptime
        // Only download/prepare when the locale isn't already installed — doing this on every start was
        // the main startup lag (seconds of dead air before the analyzer accepted audio).
        if !isInstalled, let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            elog("live[\(label)]: downloading speech model (\(loc.identifier(.bcp47)))…"); try await req.downloadAndInstall()
        }
        let t2 = ProcessInfo.processInfo.systemUptime
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, c) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        if Task.isCancelled { c.finish(); return }   // stopped mid-setup → EOF the input, don't publish
        // SpeechAnalyzer defers its model/ANE warm-up to the first audio buffer (~10s of dead air before
        // the first caption). Force it NOW, before exposing `cont`, so the warm-up runs during setup and
        // audio fed meanwhile is dropped (not queued) — the first real buffer then transcribes immediately.
        let tp = ProcessInfo.processInfo.systemUptime
        try await analyzer.prepareToAnalyze(in: fmt)
        if Task.isCancelled { c.finish(); return }   // stopped during warm-up → don't publish cont / clobber title
        lock.lock(); inputFormat = fmt; cont = c; lock.unlock()
        onLocale?(loc)   // now warm — surface the active language (replaces the "preparing" title)
        let t3 = ProcessInfo.processInfo.systemUptime
        elog(String(format: "live[%@]: analyzer ready (%@) — resolve %.1fs · assets %.1fs · start %.1fs · prepare %.1fs",
                    label, loc.identifier(.bcp47), t1 - t0, t2 - t1, tp - t2, t3 - tp))
        for try await result in transcriber.results {
            let text = String(result.text.characters)
            if !text.isEmpty { onUpdate(text, result.isFinal) }
        }
    }

    /// Map a requested locale to one SpeechTranscriber supports (exact → same-language same-region →
    /// same-language preferring en-US/GB → any same-language), preferring an already-installed one.
    private static func resolvedLocale(_ requested: Locale) async -> (locale: Locale, installed: Bool)? {
        let installed = await SpeechTranscriber.installedLocales
        if let hit = pickSpeechLocale(requested: requested, from: installed) { return (hit, true) }
        // Only query the (larger, slower) supported set when we don't already have it installed.
        let supported = await SpeechTranscriber.supportedLocales
        if let hit = pickSpeechLocale(requested: requested, from: supported) { return (hit, false) }
        return nil
    }

    /// Feed a captured PCM buffer (tap: 48 kHz stereo · mic: its native format) — convert to the
    /// analyzer's format and yield it. Called off the capture thread; the lock guards converter + cont.
    func feed(_ buf: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let cont else { return }   // analyzer not ready yet → drop
        guard let target = inputFormat else { cont.yield(AnalyzerInput(buffer: buf)); return }   // no negotiated format → pass through
        if buf.format == target { cont.yield(AnalyzerInput(buffer: buf)); return }
        if converter == nil || converter?.inputFormat != buf.format {
            converter = AVAudioConverter(from: buf.format, to: target)
        }
        guard let conv = converter else { return }
        let ratio = target.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false; var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        if err == nil, out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
    }

    func stop() {
        lock.lock(); cont?.finish(); cont = nil; lock.unlock()
        task?.cancel(); task = nil
    }
}

// MARK: - live translation providers (pluggable)
//
// A translator turns one caption line (or sentence, or the volatile tail) into the target language.
// `translate` is called many times per line off the main thread and must be cheap to call repeatedly.
// Apple's on-device Translation (LiveTranslator) is the default; a cloud provider (DeepLTranslator, …)
// conforms to the same protocol so the rest of LiveCaptions never learns which one is running — add one
// by conforming to `LiveTranslating` + a `TranslationProvider` case, its key coming from the Keychain.

/// One translation backend. Returns nil on any failure (unavailable pair, network, no key) — captions
/// then show the original text only, never a hang or an error where the translation would be.
protocol LiveTranslating: AnyObject {
    func translate(_ text: String) async -> String?
}

/// On-device translation of finalized caption lines (macOS 26 Translation framework). Best-effort:
/// if the language pair isn't installed/available it returns nil and captions show the original only.
@available(macOS 26, *)
final class LiveTranslator: LiveTranslating {
    private let session: TranslationSession
    private let lock = NSLock()
    private var prepared = false

    init(source: Locale.Language, target: Locale.Language) {
        session = TranslationSession(installedSource: source, target: target)
        // Pre-warm the pair now — the first translate can otherwise stall on the model download.
        Task { [weak self] in
            guard let self else { return }
            do { try await session.prepareTranslation(); lock.lock(); prepared = true; lock.unlock(); elog("live: translator ready") }
            catch { elog("live: translate prewarm failed: \(error)") }
        }
    }

    func translate(_ text: String) async -> String? {
        do {
            lock.lock(); let needPrep = !prepared; lock.unlock()
            if needPrep {                              // download/prepare the pair on first use
                try await session.prepareTranslation()
                lock.lock(); prepared = true; lock.unlock()   // only mark ready once prepare SUCCEEDS
            }
            return try await session.translate(text).targetText
        } catch { elog("live: translate failed: \(error)"); return nil }
    }
}

/// Selectable live-translation backend. Apple is on-device (macOS 26); DeepL is a cloud service the
/// user's key unlocks — markedly better for pairs Apple handles poorly (JA→KO, the user's main use).
/// Extensible: add a case, a title, a readiness probe, and a branch in `rebuildTranslator`.
enum TranslationProvider: String, CaseIterable {
    case apple, deepl
    var title: String {
        switch self {
        case .apple: return "Apple (on-device)"
        case .deepl: return "DeepL ☁"
        }
    }
    /// Can this provider run right now? Apple needs macOS 26; DeepL needs its API key. Offering one that
    /// can only return nil is a promise the app can't keep — `current` falls back to Apple.
    var isReady: Bool {
        switch self {
        case .apple: if #available(macOS 26, *) { return true } else { return false }
        case .deepl: return Keychain.exists("deepl") || envKeyPresent("MR_DEEPL_KEY")
        }
    }
    /// The stored provider if it can actually run, else Apple — translation must never be pinned to a
    /// provider that can only silently show the original text.
    static var current: TranslationProvider {
        let stored = TranslationProvider(rawValue: Pref.d.string(forKey: Pref.translateProvider) ?? "") ?? .apple
        return translationProvider(stored: stored, deeplReady: TranslationProvider.deepl.isReady)
    }
}

/// Pure pick: honor the stored provider, but demote DeepL to Apple when its key is absent. Selftested.
func translationProvider(stored: TranslationProvider, deeplReady: Bool) -> TranslationProvider {
    (stored == .deepl && !deeplReady) ? .apple : stored
}

/// Does a live reconfigure need to rebuild the translator? True when EITHER the target language or the
/// provider changed. The provider was the input a reconfigure used to ignore, so a Settings switch from
/// Apple to DeepL left the running overlay translating with the old backend. Pure + selftested.
func liveTranslatorNeedsRebuild(oldTarget: String, newTarget: String, oldProvider: String, newProvider: String) -> Bool {
    oldTarget != newTarget || oldProvider != newProvider
}

/// Map a BCP-47 language id ("ja", "ko-KR", "en-US") to a DeepL language code: the uppercase primary
/// subtag, with the regional variant DeepL requires for a few targets (EN→EN-US, PT→PT-PT). An unmapped
/// code passes through uppercased; DeepL then rejects it and `translate` returns nil. Selftested.
func deepLLang(_ id: String, isTarget: Bool) -> String {
    let base = id.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).uppercased() } ?? id.uppercased()
    guard isTarget else { return base }
    switch base {
    case "EN": return "EN-US"
    case "PT": return "PT-PT"
    default:   return base
    }
}

/// Cloud translation via DeepL — high quality for pairs Apple's on-device model handles poorly (JA→KO).
/// Source language is AUTO-DETECTED (robust to a mis-set caption language); only the target is fixed.
/// API key in the Keychain (Settings → Live; `MR_DEEPL_KEY`). Free keys (suffix ":fx") use the api-free
/// host. Returns nil on any failure, so captions fall back to the original text. No SDK — one POST.
/// DeepL statuses worth one retry: 429 (rate limit) and 5xx (transient server). A 4xx like bad key,
/// quota exhausted, or unsupported language won't fix itself on a retry. Pure + selftested.
func deepLShouldRetry(status: Int) -> Bool { status == 429 || (500...599).contains(status) }

final class DeepLTranslator: LiveTranslating {
    private let key: String
    private let targetLang: String
    private let endpoint: URL

    static var storedKey: String? { Keychain.get("deepl") }
    static var apiKey: String { storedKey ?? ProcessInfo.processInfo.environment["MR_DEEPL_KEY"] ?? "" }
    /// Free-tier keys end in ":fx" and MUST use the api-free host; everything else is a Pro key.
    static func endpoint(forKey k: String) -> URL {
        URL(string: k.hasSuffix(":fx") ? "https://api-free.deepl.com/v2/translate"
                                       : "https://api.deepl.com/v2/translate")!
    }

    /// nil when no key is configured — the caller falls back to Apple (or no translation).
    init?(target: Locale.Language) {
        let k = Self.apiKey
        guard !k.isEmpty else { return nil }
        self.key = k
        self.targetLang = deepLLang(target.languageCode?.identifier ?? "EN", isTarget: true)
        self.endpoint = Self.endpoint(forKey: k)
    }

    func translate(_ text: String) async -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formBody([("text", text), ("target_lang", targetLang)]).data(using: .utf8)
        // One retry on a transient failure: sentences translate as concurrent requests, so a burst can
        // trip DeepL's rate limit — and without a retry that sentence's translation is dropped for good,
        // which (in-order rendering) blanks the rest of the line's translation too.
        for attempt in 0..<2 {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                if code == 200 { return Self.parse(data) }
                // Log the body — DeepL states the reason (bad key / quota / rate limit / bad lang) in JSON.
                elog("live: DeepL HTTP \(code): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
                if !deepLShouldRetry(status: code) { return nil }   // permanent — a retry won't help
            } catch {
                elog("live: DeepL request failed: \(error)")   // network blip — retriable
            }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 400_000_000) }   // brief backoff
        }
        return nil
    }

    /// x-www-form-urlencoded body — percent-encodes every key and value (caption text can hold & = +).
    static func formBody(_ pairs: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        return pairs.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
    }

    /// Parse DeepL's {"translations":[{"text":"…"}]} → the first non-empty translation (internal: selftest).
    static func parse(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["translations"] as? [[String: Any]],
              let first = arr.first, let t = first["text"] as? String, !t.isEmpty else { return nil }
        return t
    }
}

// MARK: - live pipeline stages + interpretation (Decorator-style, pluggable) — see INTERPRETATION.md
//
// One `Utterance` flows through a chain of `UtteranceSink` stages; each wraps the next, enriches or acts,
// and forwards. Adding a capability (translate, speak, …) is composition, not rewiring. This is the
// foundation — additive and selftested; the existing caption path migrates onto it incrementally.

/// A speaker's evolving line as it moves through the pipeline. Stages read/enrich it and forward.
struct Utterance {
    let id: UUID
    let speaker: String
    var sourceText: String
    var sourceLang: String
    var isFinal: Bool
    var translation: String?
    var targetLang: String?
}

/// A pipeline stage: receive an utterance, optionally enrich/act, forward to `next`. Decorators wrap the
/// next stage; the terminal sink (the overlay) has no next.
protocol UtteranceSink: AnyObject {
    func receive(_ u: Utterance)
}

/// Text-to-speech backend for interpretation. On-device Apple now; a cloud voice conforms to the SAME
/// protocol later (the pluggability the pipeline is built around). No other stage learns which runs.
protocol SpeechSynthesizing: AnyObject {
    func speak(_ text: String, lang: String)
    func stopSpeaking()
}

/// Selectable interpretation voice — extensible exactly like LiveEngine/TranslationProvider: add a case,
/// a title, a readiness probe (a cloud voice would need its key), and a branch where the synth is built.
enum TTSProvider: String, CaseIterable {
    case apple
    var title: String { switch self { case .apple: return "Apple (on-device)" } }
    var isReady: Bool { switch self { case .apple: return true } }   // a cloud voice would check a key here
    static var current: TTSProvider {
        let stored = TTSProvider(rawValue: Pref.d.string(forKey: Pref.ttsProvider) ?? "") ?? .apple
        return stored.isReady ? stored : .apple
    }
}

/// Apple's on-device speech synthesis (AVSpeechSynthesizer). No network, no key.
final class AppleSpeechSynthesizer: SpeechSynthesizing {
    private let synth = AVSpeechSynthesizer()
    func speak(_ text: String, lang: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: lang) ?? AVSpeechSynthesisVoice(language: "ja-JP")
        synth.speak(u)
    }
    func stopSpeaking() { synth.stopSpeaking(at: .immediate) }
}

/// Whether to speak an utterance's interpretation now: once, when it is final AND translated. Pure +
/// selftested — kept out of the audio side so the SpeakingStage's gate is testable headlessly.
func shouldSpeakInterpretation(isFinal: Bool, hasTranslation: Bool, alreadySpoken: Bool) -> Bool {
    isFinal && hasTranslation && !alreadySpoken
}

/// Decorator stage: speaks the target-language translation of each final utterance (interpretation), once
/// per utterance, then forwards it unchanged. The TTS backend is pluggable (on-device or, later, cloud).
final class SpeakingStage: UtteranceSink {
    private let tts: SpeechSynthesizing
    private let next: UtteranceSink?
    private var spoken = Set<UUID>()
    init(tts: SpeechSynthesizing, next: UtteranceSink?) { self.tts = tts; self.next = next }
    func receive(_ u: Utterance) {
        if shouldSpeakInterpretation(isFinal: u.isFinal, hasTranslation: u.translation != nil,
                                     alreadySpoken: spoken.contains(u.id)),
           let t = u.translation, let lang = u.targetLang {
            spoken.insert(u.id); tts.speak(t, lang: lang)
        }
        next?.receive(u)
    }
}

// MARK: - live transcription engines (pluggable)
//
// A live engine consumes fed PCM and calls back with caption text. Two implementations today —
// Apple SpeechAnalyzer (LiveTranscriber, low latency) and whisper.cpp (WhisperLiveTranscriber, higher
// accuracy esp. non-English). Add another — on-device (sherpa-onnx, Vosk) or a paid streaming CLOUD
// API (Deepgram, OpenAI realtime, …) for low-latency + high quality — by conforming to LiveTranscribing
// (feed audio, emit text) + a LiveEngine case; its API key/endpoint would come from Prefs in init.

/// One caption source's transcription engine. `feed` is called off the audio thread; `onUpdate(text,
/// isFinal)` reports a (possibly volatile) line; `onLocale` surfaces the active language for the UI.
protocol LiveTranscribing: AnyObject {
    func start()
    func feed(_ buffer: AVAudioPCMBuffer)
    func stop()
}

func envKeyPresent(_ name: String) -> Bool {
    !(ProcessInfo.processInfo.environment[name] ?? "").isEmpty
}

/// Selectable live engine. Extensible: add a case, a title, and a branch in `makeTranscriber`.
enum LiveEngine: String, CaseIterable {
    case apple, whisper, deepgram, openai, gladia
    /// The engine in use — but only if it is still selectable. A key deleted from the Keychain, or an
    /// engine switched off in Settings, must not leave the overlay pinned to an engine that can only
    /// print an error where the captions should be.
    static var current: LiveEngine {
        let stored = LiveEngine(rawValue: Pref.d.string(forKey: Pref.liveEngine) ?? "") ?? .apple
        return stored.isSelectable ? stored : .apple
    }
    var title: String {
        switch self {
        case .apple:    return "Apple"
        case .whisper:  return "Whisper"
        case .deepgram: return "Deepgram ☁"
        case .openai:   return "OpenAI ☁"
        case .gladia:   return "Gladia ☁"
        }
    }
    /// Can this engine actually run right now? A cloud engine needs its API key; whisper needs its
    /// binary and model. Offering one that can only answer "API key not set" is a promise the app
    /// cannot keep (AGENTS.md §2.8) — Deepgram sat in the picker with no credential for exactly that reason.
    var isReady: Bool {
        switch self {
        case .apple:    return true
        case .whisper:
            let c = EngineConfig.load()
            return FileManager.default.isExecutableFile(atPath: c.whisperCli)
                && FileManager.default.fileExists(atPath: c.whisperModel)
        // Presence, never the secret: reading a key is an authorization check the user has to answer.
        case .deepgram: return Keychain.exists("deepgram") || envKeyPresent("MR_DEEPGRAM_KEY")
        case .openai:   return Keychain.exists("openai") || envKeyPresent("MR_OPENAI_KEY")
        case .gladia:   return Keychain.exists("gladia") || envKeyPresent("MR_GLADIA_KEY")
        }
    }
    /// The title without the cloud marker — a row that already sits under a vendor header shouldn't
    /// repeat the glyph, and "Apple ☁" would be a lie.
    var plainTitle: String { title.replacingOccurrences(of: " ☁", with: "") }
    /// On-device engines are on out of the box; a CLOUD engine streams meeting audio off-device, so it
    /// stays off until the user turns it on deliberately. Opt-in, never opt-out, for anything that
    /// leaves the machine.
    var onByDefault: Bool { self == .apple || self == .whisper }
    /// The user's per-engine switch (Settings › Live Captions). No stored list yet = the defaults.
    var isEnabled: Bool {
        liveEngineEnabled(self, storedOn: Pref.d.stringArray(forKey: Pref.liveEnginesOn),
                          selectedEngine: Pref.d.string(forKey: Pref.liveEngine))
    }
    var isSelectable: Bool { isReady && isEnabled }
    /// Why an engine can't be offered — shown next to its switch so the setting isn't a mystery.
    var notReadyReason: String? {
        guard !isReady else { return nil }
        return self == .whisper ? "whisper-cli or its model isn't installed yet."
                                : "Add the API key below to use this engine."
    }
}

/// A stable digest of the settings the RECORDING engine consumes. Restarting the engine throws away
/// the in-progress segment (`RecordingEngine.stop()` deletes the trailing partial), so a Save that
/// changed nothing the engine cares about must not restart it. This matters far more now that Save
/// keeps the window open: Return in any text field triggers Save, and a segment can be up to 2 hours.
/// Pure over the values, so a selftest can prove which keys do and don't trigger a restart.
func engineFingerprint(_ values: [String: String]) -> String {
    values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "\u{1}")
}

/// Is this engine switched on? With no stored list (every install that predates the switches) the
/// defaults apply — PLUS whatever engine the user had already chosen. Cloud engines becoming opt-in
/// must not silently downgrade someone who was already running Deepgram to Apple behind their back.
/// Pure + selftested.
func liveEngineEnabled(_ e: LiveEngine, storedOn: [String]?, selectedEngine: String?) -> Bool {
    if let on = storedOn { return on.contains(e.rawValue) }
    return e.onByDefault || e.rawValue == selectedEngine
}

/// Engines the user switched on that cannot run for want of a credential. Pure + selftested.
func enginesMissingCredentials(_ engines: [LiveEngine], enabled: (LiveEngine) -> Bool,
                               ready: (LiveEngine) -> Bool) -> [LiveEngine] {
    engines.filter { enabled($0) && !ready($0) }
}

/// Everything the user turned on that will silently fall back to Apple for want of a credential:
/// transcription engines switched on without a key, plus the DeepL translation provider selected
/// without a key. The on-Save warning renders exactly this list. Pure + selftested.
func missingCredentialLabels(engines: [LiveEngine], engineEnabled: (LiveEngine) -> Bool, engineReady: (LiveEngine) -> Bool,
                             translationProvider: TranslationProvider, deeplReady: Bool) -> [String] {
    var out = enginesMissingCredentials(engines, enabled: engineEnabled, ready: engineReady).map(\.plainTitle)
    if translationProvider == .deepl && !deeplReady { out.append("DeepL translation") }
    return out
}

/// The engine a popup index refers to. It indexes the FILTERED list the popup was built from — reading
/// `LiveEngine.allCases[index]` selected the wrong engine the moment any engine was left out of the
/// menu. Pure + selftested.
func engineAtPopupIndex(_ index: Int, choices: [LiveEngine]) -> LiveEngine? {
    guard !choices.isEmpty else { return nil }
    return choices[min(max(0, index), choices.count - 1)]
}

/// The engines the overlay's picker may offer: switched on by the user AND actually runnable. Apple is
/// the floor — an empty picker would strand the user with no engine and no way back. Pure + selftested.
func selectableLiveEngines(_ all: [LiveEngine], ready: (LiveEngine) -> Bool,
                           enabled: (LiveEngine) -> Bool) -> [LiveEngine] {
    // `enabled` first: it is a plain pref read, while `ready` probes the Keychain and the filesystem.
    let picked = all.filter { enabled($0) && ready($0) }
    return picked.isEmpty ? [.apple] : picked
}

/// whisper.cpp live engine: accumulates fed audio into a 16 kHz mono segment, and every ~2 s re-runs
/// `whisper-cli` on the current segment for a volatile caption line. A lightweight energy gate finalizes
/// the line after ~1 s of silence (or a 12 s cap). Reuses the same whisper-cli + model as the saved
/// transcript. Not on the real-time path — runs on its own queue. Tunables are named constants below.
final class WhisperLiveTranscriber: LiveTranscribing {
    private let label: String
    private let locale: Locale
    private let lang: String                    // whisper -l code (e.g. "ko"; "auto" if unknown)
    private let onUpdate: (String, Bool) -> Void
    private let onLocale: ((Locale) -> Void)?
    private let cfg = EngineConfig.load()
    // Same proper-noun dictionary as the saved transcript; snapshotted on q at start() (the overlay
    // builds engines on the MAIN thread, and transcriptionHints does file IO + an EventKit query —
    // review finding: a slow hints file/calendar froze the whole app). q-confined thereafter.
    private var hints = ""
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("macrec-live-\(UUID().uuidString).wav")
    private let q = DispatchQueue(label: "macrec.whisperlive", qos: .userInitiated)
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var seg: [Float] = []               // current segment samples (16 kHz mono)
    private var startedAt = 0.0                 // systemUptime when the segment began
    private var lastVoiceAt = 0.0               // systemUptime of the last non-silent buffer
    private var timer: DispatchSourceTimer?
    private var running = false                 // a whisper-cli run is in flight
    private var proc: Process?                  // the in-flight whisper-cli, so stop() can terminate it

    // Tunables (kept named for future exposure as options).
    private let tick = 1.0, minDur = 0.6, silenceGap = 0.8, maxDur = 8.0, maxWindow = 30.0
    private let voiceRMS: Float = 0.006         // ~ -44 dBFS gate — permissive; only drops true silence
    private var voicedSamples = 0               // above-threshold samples in the current segment
    private let minVoicedSec = 0.2              // require this much real speech before running whisper

    init(label: String, locale: Locale, onLocale: ((Locale) -> Void)? = nil,
         onUpdate: @escaping (String, Bool) -> Void) {
        self.label = label; self.locale = locale; self.onLocale = onLocale; self.onUpdate = onUpdate
        self.lang = locale.language.languageCode?.identifier ?? "auto"
    }

    func start() {
        onLocale?(locale)   // whisper uses the requested language directly; surface it in the title
        q.async { [weak self] in   // hints do file IO + EventKit — off the main thread, before the first tick
            guard let self else { return }
            self.hints = transcriptionHints(start: Date(), end: Date())
        }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + tick, repeating: tick)
        t.setEventHandler { [weak self] in self?.transcribeIfReady() }
        t.resume(); timer = t
        elog("whisperlive[\(label)]: started (lang=\(lang), model=\((cfg.whisperModel as NSString).lastPathComponent))")
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let conv = to16kMono(buffer), let ch = conv.floatChannelData?[0] else { return }
        let n = Int(conv.frameLength); guard n > 0 else { return }
        var sum: Float = 0; for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = (sum / Float(n)).squareRoot()
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if seg.isEmpty { startedAt = now; voicedSamples = 0 }
        seg.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
        if rms > voiceRMS { lastVoiceAt = now; voicedSamples += n }
        let cap = Int(fmt.sampleRate * maxWindow)
        if seg.count > cap { seg.removeFirst(seg.count - cap) }
        lock.unlock()
    }

    func stop() {
        timer?.cancel(); timer = nil
        lock.lock(); let p = proc; proc = nil; lock.unlock()
        p?.terminate()   // kill any in-flight whisper-cli so it doesn't keep burning CPU / leak
        q.async {   // runs after any in-flight transcribeIfReady() (serial queue) so the wav isn't recreated post-delete
            self.lock.lock(); self.seg.removeAll(); self.running = false; self.lock.unlock()
            try? FileManager.default.removeItem(at: self.wavURL)
        }
    }

    /// Convert an incoming buffer (mic native / 48 kHz tap) to 16 kHz mono float.
    private func to16kMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == fmt { return buffer }
        lock.lock()
        if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: fmt) }
        let c = converter; lock.unlock()
        guard let c else { return nil }
        let ratio = fmt.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: capacity) else { return nil }
        var fed = false; var err: NSError?
        c.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        return (err == nil && out.frameLength > 0) ? out : nil
    }

    /// Timer handler (on `q`). Snapshots the segment, decides finalize vs volatile, runs whisper-cli.
    private func transcribeIfReady() {
        lock.lock()
        if running { lock.unlock(); return }
        let samples = seg, started = startedAt, lastVoice = lastVoiceAt, voiced = voicedSamples
        lock.unlock()
        let now = ProcessInfo.processInfo.systemUptime
        let dur = Double(samples.count) / fmt.sampleRate
        guard dur >= minDur else { return }
        // Whisper hallucinates ("Thank you", "Thanks for watching"…) on silence — only run it once the segment holds
        // enough real voice; otherwise drop the silence untranscribed.
        if Double(voiced) / fmt.sampleRate < minVoicedSec {
            lock.lock(); seg.removeAll(keepingCapacity: true); startedAt = 0; voicedSamples = 0; lock.unlock()
            return
        }
        let finalize = (now - lastVoice > silenceGap) || (now - started > maxDur)
        lock.lock(); running = true; lock.unlock()
        let text = runWhisper(samples)
        if !text.isEmpty { onUpdate(text, finalize) }
        lock.lock()
        if finalize { seg.removeAll(keepingCapacity: true); startedAt = 0; voicedSamples = 0 }
        running = false
        lock.unlock()
    }

    private func runWhisper(_ samples: [Float]) -> String {
        guard FileManager.default.isExecutableFile(atPath: cfg.whisperCli),
              FileManager.default.fileExists(atPath: cfg.whisperModel) else {
            elog("whisperlive[\(label)]: whisper-cli or model missing (\(cfg.whisperCli))"); return ""
        }
        guard writeWav(samples) else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cfg.whisperCli)
        // -nt: plain text (no timestamps); -bs 1: greedy for latency; half the cores to spare the engine.
        var args = ["-m", cfg.whisperModel, "-f", wavURL.path, "-l", lang, "-nt", "-np", "-sns",
                    "-bs", "1", "-t", String(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))]
        if !hints.isEmpty { args += ["--prompt", hints] }   // same proper-noun dictionary as the saved transcript
        p.arguments = args
        let out = Pipe(); p.standardOutput = out
        p.standardError = FileHandle.nullDevice   // discard stderr — draining a Pipe we never read can deadlock waitUntilExit()
        lock.lock(); proc = p; lock.unlock()
        do { try p.run() } catch { elog("whisperlive run: \(error)"); lock.lock(); proc = nil; lock.unlock(); return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        lock.lock(); proc = nil; lock.unlock()
        let raw = String(data: data, encoding: .utf8) ?? ""
        let text = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }.joined(separator: " ")
        if text.isEmpty || p.terminationStatus != 0 { elog("whisperlive[\(label)]: whisper exit \(p.terminationStatus), raw \(raw.count) chars → empty") }
        return text
    }

    private func writeWav(_ samples: [Float]) -> Bool {
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return false }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        do {
            let file = try AVAudioFile(forWriting: wavURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buf); return true
        } catch { elog("whisperlive writeWav: \(error)"); return false }
    }
}

/// Cloud live engine: streams 16 kHz linear16 audio to Deepgram's realtime WebSocket API and maps its
/// interim/final results onto the overlay's volatile/final line model. THE ONLY feature that sends audio
/// off-device, and only while the overlay is open with this engine selected — the saved whisper transcript
/// stays fully local. Needs an API key (Settings → Live; `MR_DEEPGRAM_KEY`). No SDK — URLSessionWebSocketTask.
final class DeepgramLiveTranscriber: NSObject, LiveTranscribing, URLSessionWebSocketDelegate {
    private let label: String
    private let locale: Locale
    private let onUpdate: (String, Bool) -> Void
    private let onLocale: ((Locale) -> Void)?
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let q = DispatchQueue(label: "macrec.deepgram", qos: .userInitiated)   // serializes task/pending/stopped
    private var converter: AVAudioConverter?   // feed thread only (one capture thread per transcriber)
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pending = Data()               // audio awaiting send (batch ≈100 ms — DG likes 20–250 ms chunks)
    private var stopped = false
    private var keepalive: DispatchSourceTimer?
    private var lastSentAt = 0.0
    private let batchBytes = 1600 * 2          // 100 ms of 16 kHz Int16

    /// The key the user stored (Keychain, migrating any pre-Keychain prefs value). Used by both the
    /// engine and the Settings field, so upgraders see their key instead of an empty field. The legacy
    /// value is removed ONLY once the Keychain write is confirmed (a failed save must not drop the
    /// sole stored credential).
    static var storedKey: String? {
        if let k = Keychain.get("deepgram") { return k }
        guard !Keychain.disabled else { return nil }   // never migrate (and never delete the legacy pref) in tests
        if let k = Pref.d.string(forKey: Pref.deepgramKey), !k.isEmpty {
            if Keychain.set("deepgram", k) { Pref.d.removeObject(forKey: Pref.deepgramKey) }
            return k
        }
        return nil
    }
    static var apiKey: String { storedKey ?? ProcessInfo.processInfo.environment["MR_DEEPGRAM_KEY"] ?? "" }

    init(label: String, locale: Locale, onLocale: ((Locale) -> Void)? = nil,
         onUpdate: @escaping (String, Bool) -> Void) {
        self.label = label; self.locale = locale; self.onLocale = onLocale; self.onUpdate = onUpdate
    }

    /// The realtime endpoint for a language + hint keywords (each term becomes a `keywords` boost —
    /// same proper-noun dictionary as the saved transcript; capped for URL sanity). Pure + testable.
    static func listenURL(lang: String, keywords: [String]) -> URL {
        var comps = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        var items: [URLQueryItem] = [
            .init(name: "model", value: "nova-2"),
            .init(name: "language", value: lang),
            .init(name: "encoding", value: "linear16"),
            .init(name: "sample_rate", value: "16000"),
            .init(name: "channels", value: "1"),
            .init(name: "interim_results", value: "true"),
            .init(name: "smart_format", value: "true"),
            .init(name: "punctuate", value: "true"),
            .init(name: "endpointing", value: "300"),
        ]
        items += keywords.prefix(30).map { URLQueryItem(name: "keywords", value: $0) }
        comps.queryItems = items
        return comps.url!
    }

    func start() {
        onLocale?(locale)
        let key = Self.apiKey
        guard !key.isEmpty else {
            onUpdate("Deepgram API key not set — Settings → Live (or MR_DEEPGRAM_KEY)", true)
            elog("deepgram[\(label)]: no API key — engine idle")
            return
        }
        let lang = locale.language.languageCode?.identifier ?? "en"
        q.async { [self] in   // all connection state (task/session/pending/lastSentAt/stopped) lives on q
            guard !stopped else { return }   // stop() can land before this block on a quick toggle — don't orphan a socket
            // Hints do file IO + an EventKit query — computed HERE, not on the main thread that
            // builds engines (review finding: a slow hints file/calendar froze the app).
            let keywords = parseHintTerms(transcriptionHints(start: Date(), end: Date()))
            var req = URLRequest(url: Self.listenURL(lang: lang, keywords: keywords))
            req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
            let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let t = s.webSocketTask(with: req)
            session = s; task = t
            lastSentAt = ProcessInfo.processInfo.systemUptime   // fresh socket = no send gap yet
            t.resume()
            receiveLoop(t)
            // Deepgram closes the socket after ~10 s without messages; audio normally flows continuously
            // (silence included), but a paused/stalled source shouldn't kill the connection.
            let ka = DispatchSource.makeTimerSource(queue: q)
            ka.schedule(deadline: .now() + 5, repeating: 5)
            ka.setEventHandler { [weak self] in
                guard let self, let t = self.task, !self.stopped else { return }
                if ProcessInfo.processInfo.systemUptime - self.lastSentAt > 5 {
                    t.send(.string(#"{"type":"KeepAlive"}"#)) { _ in }
                }
            }
            ka.resume(); keepalive = ka
        }
        elog("deepgram[\(label)]: connecting (lang=\(lang))")
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        // No early `task` check — that state is q-confined (reading it here would race start()/stop()).
        // The no-connection case (e.g. missing key) just converts ~µs worth and drops inside q.async.
        guard let mono = toCanon(buffer), let ch = mono.floatChannelData?[0] else { return }
        let n = Int(mono.frameLength); guard n > 0 else { return }
        var i16 = [Int16](repeating: 0, count: n)
        for i in 0..<n { let v = max(-1, min(1, ch[i])); i16[i] = Int16(v * 32767) }
        let data = i16.withUnsafeBufferPointer { Data(buffer: $0) }   // little-endian on all Apple platforms
        q.async { [weak self] in
            guard let self, let t = self.task, !self.stopped else { return }
            self.pending.append(data)
            guard self.pending.count >= self.batchBytes else { return }
            let out = self.pending; self.pending.removeAll(keepingCapacity: true)
            self.lastSentAt = ProcessInfo.processInfo.systemUptime
            t.send(.data(out)) { [weak self] err in
                if let err, let self, !self.stopped { elog("deepgram[\(self.label)] send: \(err.localizedDescription)") }
            }
        }
    }

    func stop() {
        q.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            self.keepalive?.cancel(); self.keepalive = nil
            guard let t = self.task else { return }
            self.task = nil
            let s = self.session; self.session = nil
            if !self.pending.isEmpty {   // flush the sub-batch tail (≤100 ms) so the final caption isn't clipped
                let tail = self.pending; self.pending.removeAll(keepingCapacity: false)
                t.send(.data(tail)) { _ in }   // WebSocket frames are ordered — this precedes CloseStream
            }
            // Cancel only after CloseStream had its chance to flush — an immediate cancel can drop it.
            t.send(.string(#"{"type":"CloseStream"}"#)) { _ in
                t.cancel(with: .normalClosure, reason: nil)
                s?.finishTasksAndInvalidate()
            }
            elog("deepgram[\(self.label)]: stopped")
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.q.async {   // state (stopped) is q-confined; also serializes handle() with teardown
                guard !self.stopped else { return }
                switch result {
                case .failure(let err):
                    elog("deepgram[\(self.label)] receive: \(err.localizedDescription)")
                    self.onUpdate("(Deepgram connection lost: \(err.localizedDescription))", true)
                    // Dead connection → full teardown; otherwise KeepAlive keeps firing and feed()
                    // keeps queueing sends into a socket that will never deliver.
                    self.stopped = true
                    self.keepalive?.cancel(); self.keepalive = nil
                    self.task?.cancel(with: .abnormalClosure, reason: nil); self.task = nil
                    self.session?.finishTasksAndInvalidate(); self.session = nil
                case .success(let msg):
                    if case .string(let text) = msg { self.handle(text) }
                    self.receiveLoop(t)   // keep listening (also drains pings/metadata)
                }
            }
        }
    }

    func handle(_ text: String) {   // internal for the selftest (message-parsing is the pure logic here)
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if obj["type"] as? String == "Error" || obj["error"] != nil {
            elog("deepgram[\(label)] error message: \(text.prefix(300))")
            onUpdate("(Deepgram error — check the API key / log)", true)
            return
        }
        guard obj["type"] as? String == "Results",
              let channel = obj["channel"] as? [String: Any],
              let alts = channel["alternatives"] as? [[String: Any]],
              let transcript = alts.first?["transcript"] as? String else { return }
        let isFinal = obj["is_final"] as? Bool ?? false
        guard !transcript.isEmpty else { return }
        onUpdate(transcript, isFinal)
    }

    private func toCanon(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buf.format == fmt { return buf }
        if converter == nil || converter?.inputFormat != buf.format { converter = AVAudioConverter(from: buf.format, to: fmt) }
        guard let c = converter else { return nil }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * fmt.sampleRate / buf.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var fed = false; var err: NSError?
        c.convert(to: out, error: &err) { _, s in if fed { s.pointee = .noDataNow; return nil }; fed = true; s.pointee = .haveData; return buf }
        return (err == nil && out.frameLength > 0) ? out : nil
    }
}

/// Cloud live engine #2: OpenAI's Realtime transcription API (gpt-4o-transcribe). Streams pcm16 @ 24 kHz
/// over a WebSocket; the server VAD segments turns, transcript DELTAS append to the current line and
/// `completed` finalizes it. Same rules as Deepgram: sends audio off-device ONLY while the overlay runs
/// with this engine selected; API key in the Keychain (Settings → Live; `MR_OPENAI_KEY`). No SDK.
final class OpenAILiveTranscriber: NSObject, LiveTranscribing, URLSessionWebSocketDelegate {
    private let label: String
    private let locale: Locale
    private let onUpdate: (String, Bool) -> Void
    private let onLocale: ((Locale) -> Void)?
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private let q = DispatchQueue(label: "macrec.openailive", qos: .userInitiated)   // confines all connection state
    private var converter: AVAudioConverter?   // feed thread only (one capture thread per transcriber)
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pending = Data()               // audio awaiting send (batch ≈100 ms)
    private var accum = ""                     // running transcript of the current turn (deltas append)
    private var stopped = false
    private let batchBytes = 2400 * 2          // 100 ms of 24 kHz Int16

    static var storedKey: String? { Keychain.get("openai") }
    static var apiKey: String { storedKey ?? ProcessInfo.processInfo.environment["MR_OPENAI_KEY"] ?? "" }

    /// Realtime endpoint for a BASE (an OpenAI-compatible proxy/gateway host, e.g. a corporate LLM
    /// proxy). Accepts `https://`, `http://`, `wss://` or `ws://` bases, with or without a path prefix;
    /// http(s) is mapped to the matching WebSocket scheme and `/v1/realtime?intent=transcription` is
    /// appended. Empty/invalid → the official endpoint. Pure + testable (see `macrec selftest`).
    static func realtimeURL(base: String) -> URL {
        let official = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
        let raw = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return official }
        guard var comps = URLComponents(string: raw), let scheme = comps.scheme?.lowercased(), comps.host != nil else {
            // Don't echo the raw value — a pasted URL can carry credentials/sensitive query params.
            elog("openailive: invalid base URL (redacted) — using the official endpoint")
            return official
        }
        switch scheme {
        case "https": comps.scheme = "wss"
        case "http":  comps.scheme = "ws"
        case "wss", "ws": break
        default:
            elog("openailive: unsupported base scheme '\(scheme)' — using the official endpoint")
            return official
        }
        while comps.path.hasSuffix("/") { comps.path.removeLast() }
        comps.path += "/v1/realtime"
        // Gateways often need their own query params — keep them, but never duplicate `intent`.
        var items = (comps.queryItems ?? []).filter { $0.name != "intent" }
        items.append(URLQueryItem(name: "intent", value: "transcription"))
        comps.queryItems = items
        return comps.url ?? official
    }
    /// The configured base: an EXPLICITLY saved value (even empty = "use the official endpoint")
    /// beats the MR_OPENAI_BASE env — otherwise clearing the Settings field couldn't override the env.
    static var configuredBase: String {
        if Pref.d.object(forKey: Pref.openaiBase) != nil { return Pref.d.string(forKey: Pref.openaiBase) ?? "" }
        return ProcessInfo.processInfo.environment["MR_OPENAI_BASE"] ?? ""
    }
    static var endpoint: URL { realtimeURL(base: configuredBase) }

    /// The transcription-session config event: pcm16 in, server VAD segmenting turns; a non-empty hints
    /// dictionary rides the transcription prompt (same proper nouns as the saved transcript). Pure + testable.
    static func sessionConfig(lang: String, hints: String) -> [String: Any] {
        var transcription: [String: Any] = ["model": "gpt-4o-transcribe", "language": lang]
        if !hints.isEmpty { transcription["prompt"] = hints }
        return ["type": "transcription_session.update", "session": [
            "input_audio_format": "pcm16",
            "input_audio_transcription": transcription,
            "turn_detection": ["type": "server_vad", "silence_duration_ms": 500],
        ] as [String: Any]]
    }

    init(label: String, locale: Locale, onLocale: ((Locale) -> Void)? = nil,
         onUpdate: @escaping (String, Bool) -> Void) {
        self.label = label; self.locale = locale; self.onLocale = onLocale; self.onUpdate = onUpdate
    }

    func start() {
        onLocale?(locale)
        let key = Self.apiKey
        guard !key.isEmpty else {
            onUpdate("OpenAI API key not set — Settings → Live (or MR_OPENAI_KEY)", true)
            elog("openailive[\(label)]: no API key — engine idle")
            return
        }
        let lang = locale.language.languageCode?.identifier ?? "en"
        let endpoint = Self.endpoint
        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        q.async { [self] in
            guard !stopped else { return }   // stop() can land before this block on a quick toggle
            let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let t = s.webSocketTask(with: req)
            session = s; task = t
            t.resume()
            receiveLoop(t)
            // Configure the transcription session: raw pcm16 in, server VAD segmenting turns. The hints
            // dictionary rides the transcription prompt (same proper nouns as the saved transcript).
            let cfg = Self.sessionConfig(lang: lang, hints: transcriptionHints(start: Date(), end: Date()))
            if let d = try? JSONSerialization.data(withJSONObject: cfg), let str = String(data: d, encoding: .utf8) {
                t.send(.string(str)) { [weak self] err in
                    if let err, let self, !self.stopped { elog("openailive[\(self.label)] config: \(err.localizedDescription)") }
                }
            }
        }
        elog("openailive[\(label)]: connecting (lang=\(lang), host=\(endpoint.host ?? "?"))")
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        // No off-queue state peeks (q-confined); the no-connection case just converts ~µs and drops.
        guard let mono = toCanon(buffer), let ch = mono.floatChannelData?[0] else { return }
        let n = Int(mono.frameLength); guard n > 0 else { return }
        var i16 = [Int16](repeating: 0, count: n)
        for i in 0..<n { let v = max(-1, min(1, ch[i])); i16[i] = Int16(v * 32767) }
        let data = i16.withUnsafeBufferPointer { Data(buffer: $0) }   // little-endian on all Apple platforms
        q.async { [weak self] in
            guard let self, self.task != nil, !self.stopped else { return }
            self.pending.append(data)
            guard self.pending.count >= self.batchBytes else { return }
            let out = self.pending; self.pending.removeAll(keepingCapacity: true)
            self.sendAudio(out)
        }
    }

    private func sendAudio(_ chunk: Data) {   // caller is on q
        guard let t = task else { return }
        let msg = #"{"type":"input_audio_buffer.append","audio":""# + chunk.base64EncodedString() + #""}"#
        t.send(.string(msg)) { [weak self] err in
            if let err, let self, !self.stopped { elog("openailive[\(self.label)] send: \(err.localizedDescription)") }
        }
    }

    func stop() {
        q.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            guard let t = self.task else { return }
            self.task = nil
            let s = self.session; self.session = nil
            // Best-effort final flush: append any sub-batch tail, then COMMIT so the server transcribes
            // what it's holding before the close (server VAD normally commits on silence, but we're
            // closing now). A commit on a too-small/empty buffer can error — harmless: `stopped` is
            // already set, so the receive loop drops any late error event.
            let finish = {
                t.send(.string(#"{"type":"input_audio_buffer.commit"}"#)) { _ in
                    t.cancel(with: .normalClosure, reason: nil)
                    s?.finishTasksAndInvalidate()
                }
            }
            if !self.pending.isEmpty {
                let msg = #"{"type":"input_audio_buffer.append","audio":""# + self.pending.base64EncodedString() + #""}"#
                self.pending.removeAll(keepingCapacity: false)
                t.send(.string(msg)) { _ in finish() }
            } else {
                finish()
            }
            elog("openailive[\(self.label)]: stopped")
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.q.async {   // state is q-confined; also serializes handle() with teardown
                guard !self.stopped else { return }
                switch result {
                case .failure(let err):
                    elog("openailive[\(self.label)] receive: \(err.localizedDescription)")
                    self.onUpdate("(OpenAI connection lost: \(err.localizedDescription))", true)
                    // Dead connection → full teardown; nothing should keep sending into it.
                    self.stopped = true
                    self.task?.cancel(with: .abnormalClosure, reason: nil); self.task = nil
                    self.session?.finishTasksAndInvalidate(); self.session = nil
                case .success(let msg):
                    if case .string(let text) = msg { self.handle(text) }
                    self.receiveLoop(t)
                }
            }
        }
    }

    func handle(_ text: String) {   // internal for the selftest (event parsing is the pure logic here)
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = obj["delta"] as? String, !delta.isEmpty else { return }
            accum += delta                     // OpenAI deltas APPEND (Deepgram interims replace)
            onUpdate(accum, false)
        case "conversation.item.input_audio_transcription.completed":
            let transcript = obj["transcript"] as? String ?? accum
            accum = ""
            guard !transcript.isEmpty else { return }
            onUpdate(transcript, true)
        case "error":
            elog("openailive[\(label)] error: \(text.prefix(300))")
            onUpdate("(OpenAI error — check the API key / log)", true)
        default: break   // session.created / committed / speech_started … — not caption-relevant
        }
    }

    private func toCanon(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buf.format == fmt { return buf }
        if converter == nil || converter?.inputFormat != buf.format { converter = AVAudioConverter(from: buf.format, to: fmt) }
        guard let c = converter else { return nil }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * fmt.sampleRate / buf.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var fed = false; var err: NSError?
        c.convert(to: out, error: &err) { _, s in if fed { s.pointee = .noDataNow; return nil }; fed = true; s.pointee = .haveData; return buf }
        return (err == nil && out.frameLength > 0) ? out : nil
    }
}

/// Cloud live engine #3: Gladia realtime v2 — notable for broad language coverage including Korean
/// STREAMING (the reason it was picked over AssemblyAI, whose realtime is English-centric). Two-step
/// protocol: a REST init (X-Gladia-Key) returns a single-use WebSocket URL; audio then streams as
/// binary pcm16 @ 16 kHz. Same rules as the other cloud engines: audio leaves the device ONLY while
/// the overlay runs with this engine; key in the Keychain (Settings → Live; MR_GLADIA_KEY). No SDK.
final class GladiaLiveTranscriber: NSObject, LiveTranscribing, URLSessionWebSocketDelegate {
    private let label: String
    private let locale: Locale
    private let onUpdate: (String, Bool) -> Void
    private let onLocale: ((Locale) -> Void)?
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let q = DispatchQueue(label: "macrec.gladialive", qos: .userInitiated)   // confines all connection state
    private var converter: AVAudioConverter?   // feed thread only (one capture thread per transcriber)
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pending = Data()               // audio awaiting send (batch ≈100 ms)
    private var stopped = false
    private let batchBytes = 1600 * 2          // 100 ms of 16 kHz Int16

    static var storedKey: String? { Keychain.get("gladia") }
    static var apiKey: String { storedKey ?? ProcessInfo.processInfo.environment["MR_GLADIA_KEY"] ?? "" }

    init(label: String, locale: Locale, onLocale: ((Locale) -> Void)? = nil,
         onUpdate: @escaping (String, Bool) -> Void) {
        self.label = label; self.locale = locale; self.onLocale = onLocale; self.onUpdate = onUpdate
    }

    /// The REST-init body: stream format + language + the hints dictionary as custom vocabulary.
    /// Pure + testable (see `macrec selftest`).
    static func initBody(lang: String, vocabulary: [String]) -> [String: Any] {
        var body: [String: Any] = [
            "encoding": "wav/pcm", "sample_rate": 16000, "bit_depth": 16, "channels": 1,
        ]
        if !lang.isEmpty { body["language_config"] = ["languages": [lang], "code_switching": false] }
        if !vocabulary.isEmpty {
            body["realtime_processing"] = ["custom_vocabulary": true,
                                           "custom_vocabulary_config": ["vocabulary": vocabulary]] as [String: Any]
        }
        return body
    }

    func start() {
        onLocale?(locale)
        let key = Self.apiKey
        guard !key.isEmpty else {
            onUpdate("Gladia API key not set — Settings → Live (or MR_GLADIA_KEY)", true)
            elog("gladialive[\(label)]: no API key — engine idle")
            return
        }
        let lang = locale.language.languageCode?.identifier ?? ""
        elog("gladialive[\(label)]: requesting session (lang=\(lang.isEmpty ? "auto" : lang))")
        q.async { [self] in
            guard !stopped else { return }
            // Hints do file IO + an EventKit query — computed HERE, not on the main thread that
            // builds engines (review finding: a slow hints file/calendar froze the app).
            let vocab = parseHintTerms(transcriptionHints(start: Date(), end: Date()))
            var req = URLRequest(url: URL(string: "https://api.gladia.io/v2/live")!)
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "X-Gladia-Key")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: Self.initBody(lang: lang, vocabulary: vocab))
            startSession(req)
        }
    }

    private func startSession(_ req: URLRequest) {   // on q
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            self.q.async {
                guard !self.stopped else { return }   // stop() can land before the session arrives
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                guard err == nil, (200..<300).contains(status), let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let urlStr = obj["url"] as? String, let wsURL = URL(string: urlStr) else {
                    elog("gladialive[\(self.label)] init failed: status \(status) \(err?.localizedDescription ?? "")")
                    self.onUpdate("(Gladia session failed — check the API key / log)", true)
                    return
                }
                let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                let t = s.webSocketTask(with: wsURL)   // single-use URL carries the auth token
                self.session = s; self.task = t
                t.resume()
                self.receiveLoop(t)
                if !self.pending.isEmpty {   // flush the PRE-ROLL buffered while the REST init ran
                    let out = self.pending; self.pending.removeAll(keepingCapacity: true)
                    t.send(.data(out)) { [weak self] err in
                        if let err, let self, !self.stopped { elog("gladialive[\(self.label)] preroll send: \(err.localizedDescription)") }
                    }
                }
            }
        }.resume()
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        // No off-queue state peeks (q-confined); the no-connection case just converts ~µs and drops.
        guard let mono = toCanon(buffer), let ch = mono.floatChannelData?[0] else { return }
        let n = Int(mono.frameLength); guard n > 0 else { return }
        var i16 = [Int16](repeating: 0, count: n)
        for i in 0..<n { let v = max(-1, min(1, ch[i])); i16[i] = Int16(v * 32767) }
        let data = i16.withUnsafeBufferPointer { Data(buffer: $0) }   // little-endian on all Apple platforms
        q.async { [weak self] in
            guard let self, !self.stopped else { return }
            // PRE-ROLL: unlike the other engines, the socket only exists after Gladia's REST init
            // returns — audio spoken during that round trip must buffer, not drop (review finding:
            // the opening words after enabling captions were lost). Cap ~30 s in case init hangs.
            self.pending.append(data)
            if self.pending.count > 16000 * 2 * 30 { self.pending.removeFirst(self.pending.count - 16000 * 2 * 30) }
            guard let t = self.task, self.pending.count >= self.batchBytes else { return }
            let out = self.pending; self.pending.removeAll(keepingCapacity: true)
            t.send(.data(out)) { [weak self] err in
                if let err, let self, !self.stopped { elog("gladialive[\(self.label)] send: \(err.localizedDescription)") }
            }
        }
    }

    func stop() {
        q.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            guard let t = self.task else { return }
            self.task = nil
            let s = self.session; self.session = nil
            if !self.pending.isEmpty {   // flush the sub-batch tail so the final words aren't clipped
                let tail = self.pending; self.pending.removeAll(keepingCapacity: false)
                t.send(.data(tail)) { _ in }   // frames are ordered — precedes stop_recording
            }
            t.send(.string(#"{"type":"stop_recording"}"#)) { _ in
                t.cancel(with: .normalClosure, reason: nil)
                s?.finishTasksAndInvalidate()
            }
            elog("gladialive[\(self.label)]: stopped")
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.q.async {   // state is q-confined; also serializes handle() with teardown
                guard !self.stopped else { return }
                switch result {
                case .failure(let err):
                    elog("gladialive[\(self.label)] receive: \(err.localizedDescription)")
                    self.onUpdate("(Gladia connection lost: \(err.localizedDescription))", true)
                    self.stopped = true   // dead connection → full teardown
                    self.task?.cancel(with: .abnormalClosure, reason: nil); self.task = nil
                    self.session?.finishTasksAndInvalidate(); self.session = nil
                case .success(let msg):
                    if case .string(let text) = msg { self.handle(text) }
                    self.receiveLoop(t)
                }
            }
        }
    }

    func handle(_ text: String) {   // internal for the selftest (message parsing is the pure logic here)
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "transcript":
            guard let d = obj["data"] as? [String: Any],
                  let utterance = d["utterance"] as? [String: Any],
                  let t = utterance["text"] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            onUpdate(t.trimmingCharacters(in: .whitespaces), (d["is_final"] as? Bool) ?? false)
        case "error":
            elog("gladialive[\(label)] error: \(text.prefix(300))")
            onUpdate("(Gladia error — check the API key / log)", true)
        default: break   // audio_chunk acks / lifecycle events — not caption-relevant
        }
    }

    private func toCanon(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buf.format == fmt { return buf }
        if converter == nil || converter?.inputFormat != buf.format { converter = AVAudioConverter(from: buf.format, to: fmt) }
        guard let c = converter else { return nil }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * fmt.sampleRate / buf.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var fed = false; var err: NSError?
        c.convert(to: out, error: &err) { _, s in if fed { s.pointee = .noDataNow; return nil }; fed = true; s.pointee = .haveData; return buf }
        return (err == nil && out.frameLength > 0) ? out : nil
    }
}

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
        var transTail: String? = nil        // live translation of the UNFINISHED tail (volatile)
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
    func toggle() { active ? stop() : start() }

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

/// How many lines a subtitle shows. A film shows one utterance, two lines at most — a scrolling wall of
/// history is the thing that makes an overlay read as a log. Pure + selftested.
let subtitleMaxLines = 2

/// The window outline exists so a transparent LOG still reads as a window you can grab. A subtitle is
/// not a window — a rectangle drawn around a film subtitle is exactly what breaks the illusion.
/// Pure + selftested.
func captionEdgeVisible(subtitle: Bool) -> Bool { !subtitle }

/// Do the captions have to carry their own contrast? Only when the backdrop is too faint to provide it.
/// A backplate behind text that already sits on a solid panel would just be a darker box on a dark box.
/// Pure + selftested.
func captionTextNeedsBackplate(backdropAlpha: CGFloat) -> Bool { backdropAlpha < 0.6 }

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
        backdrop.alphaValue = captionBackdropAlpha(Pref.dbl(Pref.liveOpacity, "MR_LIVE_OPACITY", 1.0))
        content.addSubview(backdrop)
        let scroll = NSScrollView(frame: content.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay        // auto-hiding overlay scroller (no permanent bar)
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
        let opacity = NSSlider(value: Double(captionBackdropAlpha(Pref.dbl(Pref.liveOpacity, "MR_LIVE_OPACITY", 1.0))),
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
        let subFont = NSFont.systemFont(ofSize: max(11, size - 6), weight: .regular)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineHeightMultiple = 1.15
        para.paragraphSpacing = 6
        // Contrast goes behind the glyphs, never into them — a `strokeWidth` outline reads as a heavier
        // font weight. A shadow alone is not enough: against a bright window the captions all but vanish
        // (seen in `caption-snapshot`). Centred text makes a `.backgroundColor` run hug the line, which is
        // the black band broadcast subtitles use — and it only appears when the backdrop can't do the job.
        let plate = captionTextNeedsBackplate(backdropAlpha: captionBackdropAlpha(Pref.dbl(Pref.liveOpacity, "MR_LIVE_OPACITY", 1.0)))
            ? NSColor.black.withAlphaComponent(0.6) : NSColor.clear
        let halo = NSShadow()
        halo.shadowColor = NSColor.black.withAlphaComponent(0.85)
        halo.shadowBlurRadius = 2
        halo.shadowOffset = NSSize(width: 0, height: -1)

        let out = NSMutableAttributedString()
        for (i, l) in lines.suffix(subtitleMaxLines).enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            let (main, secondary) = subtitleLine(original: l.text, translated: l.translated)
            if let secondary {
                out.append(NSAttributedString(string: secondary + "\n", attributes: [
                    .font: subFont, .foregroundColor: NSColor.secondaryLabelColor,
                    .backgroundColor: plate, .shadow: halo, .paragraphStyle: para]))
            }
            out.append(NSAttributedString(string: main, attributes: [
                .font: mainFont, .foregroundColor: NSColor.labelColor,
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
            if showTimestamps {
                out.append(NSAttributedString(string: "\(tsFormatter.string(from: l.time))  ", attributes: [
                    .font: tsFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
            }
            if showLabels {
                out.append(NSAttributedString(string: "\(l.speaker)  ", attributes: [
                    .font: labelFont, .foregroundColor: tint, .paragraphStyle: para]))
            }
            if hasPrefix { out.append(NSAttributedString(string: "\t", attributes: [.font: textFont, .paragraphStyle: para])) }
            out.append(NSAttributedString(string: l.text, attributes: [   // text stays neutral like single-speaker mode
                .font: textFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: para]))
            if l.inProgress {   // still transcribing this line → typing indicator inside the text
                out.append(NSAttributedString(string: (l.text.isEmpty ? "…" : " …"), attributes: [
                    .font: textFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
            }
            if let t = l.translated, !t.isEmpty {
                out.append(NSAttributedString(string: "\n↳ ", attributes: [
                    .font: markFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: trans]))
                // The translation carries the SPEAKER's tint (source text stays neutral) — the two
                // layers separate at a glance instead of being two near-identical white lines.
                out.append(NSAttributedString(string: t, attributes: [
                    .font: transFont, .foregroundColor: tint.withAlphaComponent(0.95), .paragraphStyle: trans]))
            }
        }
        // Over a see-through backdrop the captions sit on whatever is behind the window — light slides,
        // white documents — and vanish. The two treatments that DON'T work: a blurred halo smears the
        // thin strokes, and a negative `strokeWidth` outlines the glyphs, which reads as a heavier
        // weight. Neither may touch the letterforms. So put the contrast BEHIND them, as broadcast
        // captions do: a dark plate hugging the text, drawn only when the backdrop can't do the job.
        if captionTextNeedsBackplate(backdropAlpha: captionBackdropAlpha(Pref.dbl(Pref.liveOpacity, "MR_LIVE_OPACITY", 1.0))) {
            out.addAttribute(.backgroundColor, value: NSColor.black.withAlphaComponent(0.55),
                             range: NSRange(location: 0, length: out.length))
        }
        textView.textStorage?.setAttributedString(out)
        textView.scrollToEndOfDocument(nil)
    }

    // User clicked the panel's close button → tear the session down (unless we closed it ourselves).
    func windowWillClose(_ notification: Notification) { if !suppressCloseCallback { onClose() } }
}
