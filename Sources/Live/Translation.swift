import AppKit
import AVFoundation
import Foundation
import Speech
import Translation

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
/// Live translation via Apple's Translation framework (on-device, macOS 26+).
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

/// Live translation via the DeepL API (needs an API key).
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
