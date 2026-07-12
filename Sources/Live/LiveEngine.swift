import AppKit
import AVFoundation
import Foundation
import Speech
import Translation

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
    case apple, whisper, deepgram, openai, gladia, elevenlabs
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
        case .elevenlabs: return "ElevenLabs ☁"
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
        case .elevenlabs: return Keychain.exists("elevenlabs") || envKeyPresent("MR_ELEVENLABS_KEY")
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

