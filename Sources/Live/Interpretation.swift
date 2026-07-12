import AppKit
import AVFoundation
import Foundation
import Speech
import Translation

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

