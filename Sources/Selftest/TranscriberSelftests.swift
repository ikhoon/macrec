import AppKit
import AVFoundation
import EventKit
import Foundation

func transcriberSelftests(_ check: (String, Bool) -> Void) {
    // Deepgram engine: realtime-message parsing (interim → volatile, is_final → final, junk ignored).
    var dgGot: [(String, Bool)] = []
    let dg = DeepgramLiveTranscriber(label: "t", locale: Locale(identifier: "ko-KR")) { s, f in dgGot.append((s, f)) }
    dg.handle(#"{"type":"Results","is_final":false,"channel":{"alternatives":[{"transcript":"안녕하세요"}]}}"#)
    dg.handle(#"{"type":"Results","is_final":true,"channel":{"alternatives":[{"transcript":"안녕하세요 반갑습니다"}]}}"#)
    dg.handle(#"{"type":"Results","is_final":true,"channel":{"alternatives":[{"transcript":""}]}}"#)   // empty → dropped
    dg.handle(#"{"type":"Metadata","request_id":"x"}"#)                                                // non-result → dropped
    dg.handle("not json at all")                                                                       // junk → dropped
    check("deepgram: interim/final parsing", dgGot.count == 2
          && dgGot[0] == ("안녕하세요", false) && dgGot[1] == ("안녕하세요 반갑습니다", true))
    // OpenAI Realtime engine: deltas APPEND to the running line; completed finalizes and resets.
    var oaGot: [(String, Bool)] = []
    let oa = OpenAILiveTranscriber(label: "t", locale: Locale(identifier: "ko-KR")) { s, f in oaGot.append((s, f)) }
    oa.handle(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"안녕"}"#)
    oa.handle(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"하세요"}"#)
    oa.handle(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"안녕하세요"}"#)
    oa.handle(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"반갑"}"#)   // new turn restarts
    oa.handle(#"{"type":"session.created"}"#)                                                    // non-caption → dropped
    oa.handle("junk")                                                                            // junk → dropped
    check("openai: delta accumulation + completed reset", oaGot.count == 4
          && oaGot[0] == ("안녕", false) && oaGot[1] == ("안녕하세요", false)
          && oaGot[2] == ("안녕하세요", true) && oaGot[3] == ("반갑", false))
    // OpenAI base-URL mapping (corporate proxies/gateways): https→wss, path prefix kept,
    // trailing slash trimmed, invalid/garbage falls back to the official endpoint.
    func oaURL(_ b: String) -> String { OpenAILiveTranscriber.realtimeURL(base: b).absoluteString }
    let oaOfficial = "wss://api.openai.com/v1/realtime?intent=transcription"
    check("openai base: empty → official", oaURL("") == oaOfficial)
    check("openai base: https proxy + path", oaURL("https://llm.corp.example/openai/") ==
          "wss://llm.corp.example/openai/v1/realtime?intent=transcription")
    check("openai base: ws + port kept", oaURL("ws://localhost:8080") ==
          "ws://localhost:8080/v1/realtime?intent=transcription")
    check("openai base: garbage → official", oaURL("ftp://nope") == oaOfficial && oaURL("::::") == oaOfficial)
    check("openai base: gateway query kept, intent deduped", oaURL("https://gw.example/x?intent=foo&team=a") ==
          "wss://gw.example/x/v1/realtime?team=a&intent=transcription")
    // ElevenLabs Scribe: realtime-message parsing. partial_transcript is the full current partial
    // (REPLACES the volatile line); committed_transcript finalizes; junk/session/error → no caption.
    var elGot: [(String, Bool)] = []
    let el = ElevenLabsLiveTranscriber(label: "t", locale: Locale(identifier: "ja-JP")) { s, f in elGot.append((s, f)) }
    el.handle(#"{"message_type":"session_started","session_id":"x"}"#)                       // control → dropped
    el.handle(#"{"message_type":"partial_transcript","text":"こん"}"#)                        // interim
    el.handle(#"{"message_type":"partial_transcript","text":"こんにちは"}"#)                  // interim (replaces)
    el.handle(#"{"message_type":"committed_transcript","text":"こんにちは"}"#)                // final
    el.handle(#"{"message_type":"partial_transcript","text":""}"#)                            // empty → dropped
    el.handle("not json")                                                                     // junk → dropped
    check("elevenlabs: partial replaces, committed finalizes", elGot.count == 3
          && elGot[0] == ("こん", false) && elGot[1] == ("こんにちは", false) && elGot[2] == ("こんにちは", true))
    // The realtime URL carries the Scribe v2 model, 16k PCM, server VAD, and the ISO-639-1 language;
    // an empty language omits language_code (server auto-detects).
    let elURL = ElevenLabsLiveTranscriber.realtimeURL(lang: "ko").absoluteString
    check("elevenlabs url: model + pcm16 + vad + language_code",
          elURL.hasPrefix("wss://api.elevenlabs.io/v1/speech-to-text/realtime?")
          && elURL.contains("model_id=scribe_v2_realtime") && elURL.contains("audio_format=pcm_16000")
          && elURL.contains("commit_strategy=vad") && elURL.contains("language_code=ko")
          && !ElevenLabsLiveTranscriber.realtimeURL(lang: "").absoluteString.contains("language_code"))
    // convert16 hands finishOrDiscard the .16.wav it just created; a throwing write must delete that
    // partial, a successful write must keep it.
    let cvTmp = FileManager.default.temporaryDirectory.appendingPathComponent("macrec-cv-\(UUID().uuidString).16.wav")
    FileManager.default.createFile(atPath: cvTmp.path, contents: Data([0, 0]))       // the caller's just-created output
    let cvExisted = FileManager.default.fileExists(atPath: cvTmp.path)
    let cvFailed = Transcriber.finishOrDiscard(cvTmp) { throw NSError(domain: "selftest.convert16", code: 1) }
    check("convert16 cleanup: a throwing write removes the partial it was handed",
          cvExisted && cvFailed == nil && !FileManager.default.fileExists(atPath: cvTmp.path))
    FileManager.default.createFile(atPath: cvTmp.path, contents: Data([0, 0]))
    let cvOK = Transcriber.finishOrDiscard(cvTmp) {}
    check("convert16 cleanup: a successful write keeps the file",
          cvOK == cvTmp && FileManager.default.fileExists(atPath: cvTmp.path))
    try? FileManager.default.removeItem(at: cvTmp)   // don't leave the test's own artifact
}
