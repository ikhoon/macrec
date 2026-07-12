import AppKit
import AVFoundation
import EventKit
import Foundation

func localeSelftests(_ check: (String, Bool) -> Void) {
    // Live-caption locale mapping (regression: Locale.current can be en_KR, which SpeechTranscriber
    // rejects with "unsupported locale" — must map to a supported one).
    let pool = ["fr-FR", "ko-KR", "zh-CN", "es-ES", "es-US", "en-GB", "en-AU", "en-US", "ja-JP"].map { Locale(identifier: $0) }
    func pick(_ id: String) -> String? { pickSpeechLocale(requested: Locale(identifier: id), from: pool)?.identifier(.bcp47) }
    check("en_KR → en-US (prefer -US)", pick("en_KR") == "en-US")
    check("ko_KR → ko-KR (exact-ish)",  pick("ko_KR") == "ko-KR")
    check("ja_JP → ja-JP",              pick("ja_JP") == "ja-JP")
    check("en-GB → en-GB (exact)",      pick("en-GB") == "en-GB")
    check("es_MX → same-language es",   pick("es_MX") == "es-US" || pick("es_MX") == "es-ES")
    check("unsupported lang → nil",     pick("sw_TZ") == nil)
    check("labels ko → 나/상대",         speakerLabels(forLanguage: "ko") == ("나", "상대"))
    check("labels en → Me/Them",        speakerLabels(forLanguage: "en") == ("Me", "Them"))
    check("labels ja → 私/相手",         speakerLabels(forLanguage: "ja") == ("私", "相手"))
    check("labels zh → 我/对方",         speakerLabels(forLanguage: "zh") == ("我", "对方"))
    check("labels nil → Me/Them",       speakerLabels(forLanguage: nil) == ("Me", "Them"))
    check("labels unmapped → Me/Them",  speakerLabels(forLanguage: "fr") == ("Me", "Them"))
}
