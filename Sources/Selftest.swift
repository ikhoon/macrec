// Self-tests: pure decisions and headless UI assertions. Run: `macrec selftest`.
//
// Kept apart from the app so the suite can grow without the app file growing with it. Every check
// reproduces a real failure with the values from the incident (AGENTS.md).

import AppKit
import AVFoundation
import EventKit
import Foundation

/// Runs every check, prints a line per check, and exits: 0 when all pass, 1 otherwise.
func runSelftest() -> Never {
            var fails = 0
            func check(_ name: String, _ ok: Bool) { print("\(ok ? "ok  " : "FAIL") \(name)"); if !ok { fails += 1 } }
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
            // EchoCanceller (SpeexDSP AEC) framing/plumbing — deterministic, no audio device needed.
            // Guards the contract: the mic ALWAYS flows through (cumulative out ≈ in, ±one buffered frame),
            // whether or not a reference is present — a regression that starved the mic would fail here.
            let ecFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            func ecBuf(_ n: Int) -> AVAudioPCMBuffer {
                let b = AVAudioPCMBuffer(pcmFormat: ecFmt, frameCapacity: AVAudioFrameCount(n))!
                b.frameLength = AVAudioFrameCount(n)
                let ch = b.floatChannelData![0]; for i in 0..<n { ch[i] = 0.3 * sinf(Float(i) * 0.19) }
                return b
            }
            EchoCanceller.shared.reset()
            var ecIn = 0, ecOut = 0
            for _ in 0..<40 {
                EchoCanceller.shared.pushReference(ecBuf(171))                       // far-end reference
                ecOut += EchoCanceller.shared.cancelMic(ecBuf(171)).map { Int($0.frameLength) } ?? -99999
                ecIn += 171
            }
            check("AEC framing: mic flows (out ≈ in, with reference)", ecIn - ecOut >= 0 && ecIn - ecOut <= 512)
            EchoCanceller.shared.reset()   // no reference at all → mic must still pass through, never back up
            var nrIn = 0, nrOut = 0
            for _ in 0..<40 { nrOut += EchoCanceller.shared.cancelMic(ecBuf(171)).map { Int($0.frameLength) } ?? -99999; nrIn += 171 }
            check("AEC framing: mic flows (out ≈ in, no reference)", nrIn - nrOut >= 0 && nrIn - nrOut <= 256 * 5)
            // Jitter regression: the MEASURED real-world cadence — the mic delivering in ~32 ms clumps
            // (3×171) against a steady per-chunk reference — must trim ZERO samples and zero-pad ZERO
            // samples. Trimming/starving on this normal jitter shredded the reference continuity and
            // pinned real-call ERLE at ~6 dB (the "echo not improved" bug).
            EchoCanceller.shared.reset()
            _ = EchoCanceller.shared.cancelMic(ecBuf(256))     // anchor the pairing offset
            EchoCanceller.shared.pushReference(ecBuf(512))     // steady-state headroom like a live stream
            let jt = EchoCanceller.shared.trimsForTest, js = EchoCanceller.shared.starvesForTest
            for _ in 0..<100 {
                for _ in 0..<3 { EchoCanceller.shared.pushReference(ecBuf(171)) }   // tap: continuous
                for _ in 0..<3 { _ = EchoCanceller.shared.cancelMic(ecBuf(171)) }   // mic: clumped
            }
            check("AEC jitter: clumped mic delivery → 0 trimmed / 0 zero-padded samples",
                  EchoCanceller.shared.trimsForTest == jt && EchoCanceller.shared.starvesForTest == js)
            // Staleness invariant: the reference backlog the tap builds while the mic spins up must be
            // dropped when the stream anchors (first drain) — a persistent backlog makes the causal
            // filter cancel 0 dB for the whole session (regression found by adversarial review).
            EchoCanceller.shared.reset()
            EchoCanceller.shared.pushReference(ecBuf(6000))         // tap pre-fill during mic spin-up (capped)
            _ = EchoCanceller.shared.cancelMic(ecBuf(512))          // first drain anchors the pairing offset
            check("AEC staleness: startup backlog anchored to ≤ 512", EchoCanceller.shared.refDepthForTest <= 512)
            // Gap/reset invariant: buffered mic residue must not leak into a later stream.
            EchoCanceller.shared.reset()
            _ = EchoCanceller.shared.cancelMic(ecBuf(100))          // sub-frame residue stays buffered…
            let residue = EchoCanceller.shared.micDepthForTest == 100
            EchoCanceller.shared.reset()                            // …until a reset (or a mic-gap self-heal)
            check("AEC reset: buffered mic residue cleared", residue && EchoCanceller.shared.micDepthForTest == 0)
            // Constant-relation regression: the ring cap must outlast the gap-heal threshold (see maxRef).
            check("AEC invariant: ring cap covers the gap-heal window", EchoCanceller.shared.capCoversGapForTest)
            // Garbage tuning knobs (NaN / overflow env-style values) must not trap during preprocessor
            // (re)creation — Int32(Double.nan) crashes if unsanitized. Uses the real prefs path; cleaned up.
            Pref.d.set(Double.nan, forKey: "echoSuppress")
            Pref.d.set(1e308, forKey: "echoSuppressActive")
            _ = EchoCanceller.shared.cancelMic(ecBuf(256))   // ensure the echo state exists
            EchoCanceller.shared.reset()                     // recreates the preprocessor → reads the knobs
            // Getting ANY buffer back is the pass condition — an unsanitized Int32(NaN) traps before
            // returning. (0 frames is correct here: no reference yet → wait-for-ref holds the mic.)
            let knobOut = EchoCanceller.shared.cancelMic(ecBuf(256)).map { Int($0.frameLength) } ?? -1
            Pref.d.removeObject(forKey: "echoSuppress"); Pref.d.removeObject(forKey: "echoSuppressActive")
            EchoCanceller.shared.reset()                     // back to sane knobs for any later checks
            check("AEC knobs: garbage prefs don't crash preprocessor init", knobOut >= 0)
            // AEC reference gating (#29): when the dedicated full-mix reference tap is live, appendSys must
            // NOT also push the filtered mix as reference — a double feed corrupts the FIFO pairing the AEC
            // relies on. This is the seam the shouldStartReferenceTap decision test can't see (that's the
            // *choice*; this is the *wiring* that honors it).
            Pref.d.set(true, forKey: Pref.echoReduce)
            EchoCanceller.shared.reset()
            let gateRec = Recorder(sysWriter: nil, micWriter: nil)
            gateRec.referenceComesFromFullMixTap = true       // full-mix tap owns the reference…
            let gateBase = EchoCanceller.shared.refDepthForTest
            gateRec.appendSys(ecBuf(256))
            let gatedOff = EchoCanceller.shared.refDepthForTest == gateBase     // …so appendSys pushes nothing
            gateRec.referenceComesFromFullMixTap = false      // no full-mix tap → the filtered mix IS the reference
            gateRec.appendSys(ecBuf(256))
            let gatedOn = EchoCanceller.shared.refDepthForTest > gateBase       // …so appendSys pushes it
            Pref.d.removeObject(forKey: Pref.echoReduce)
            EchoCanceller.shared.reset()
            check("AEC reference gating: live full-mix tap suppresses the filtered-mix reference push", gatedOff && gatedOn)
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
            // Live translation provider: DeepL is honored only with a key, else demote to Apple — the same
            // "don't offer what can't run" rule the transcription engines follow. Pure decision.
            check("translate provider: DeepL needs a key, else Apple",
                  translationProvider(stored: .deepl, deeplReady: true)  == .deepl
                  && translationProvider(stored: .deepl, deeplReady: false) == .apple   // no key → fall back
                  && translationProvider(stored: .apple, deeplReady: true)  == .apple)
            // DeepL language mapping: uppercase primary subtag; targets that DeepL requires a regional
            // variant for (EN, PT) get one; source keeps the base. (The user's pair is JA→KO.)
            check("deepl lang: BCP-47 → DeepL code",
                  deepLLang("ja", isTarget: true) == "JA" && deepLLang("ko-KR", isTarget: true) == "KO"
                  && deepLLang("en", isTarget: true) == "EN-US" && deepLLang("en", isTarget: false) == "EN"
                  && deepLLang("pt-BR", isTarget: true) == "PT-PT")
            // DeepL free vs pro endpoint is decided by the key suffix (":fx" = free tier, different host).
            check("deepl endpoint: :fx → api-free host, else pro host",
                  DeepLTranslator.endpoint(forKey: "abc:fx").host == "api-free.deepl.com"
                  && DeepLTranslator.endpoint(forKey: "abc").host == "api.deepl.com")
            // DeepL retry policy: retry only transient failures (429 rate-limit, 5xx). A 4xx (bad key,
            // quota, unsupported language) won't fix itself — retrying would just double the load.
            check("deepl retry: only 429 + 5xx are retried",
                  deepLShouldRetry(status: 429) && deepLShouldRetry(status: 500) && deepLShouldRetry(status: 503)
                  && !deepLShouldRetry(status: 200) && !deepLShouldRetry(status: 403)
                  && !deepLShouldRetry(status: 456) && !deepLShouldRetry(status: 400))
            // DeepL response parsing: first non-empty translation; malformed/empty → nil (captions then
            // show the original, never a crash or a blank line).
            func dlParse(_ s: String) -> String? { DeepLTranslator.parse(s.data(using: .utf8)!) }
            check("deepl parse: translations[0].text, else nil",
                  dlParse(#"{"translations":[{"detected_source_language":"JA","text":"안녕하세요"}]}"#) == "안녕하세요"
                  && dlParse(#"{"translations":[]}"#) == nil
                  && dlParse(#"{"message":"Wrong endpoint"}"#) == nil
                  && dlParse("not json") == nil)
            // form body must percent-encode reserved chars so caption text with & = + never breaks the POST.
            check("deepl form: reserved chars encoded",
                  DeepLTranslator.formBody([("text", "a & b=c+d"), ("target_lang", "KO")])
                  == "text=a%20%26%20b%3Dc%2Bd&target_lang=KO")
            // Reconfigure seam: switching the provider in Settings (target language unchanged) must rebuild
            // the running overlay's translator — the exact input reconfigure used to ignore, so an
            // Apple→DeepL switch kept translating on Apple until the overlay was toggled off/on.
            check("live: translator rebuilds on a provider change, not just a target change",
                  liveTranslatorNeedsRebuild(oldTarget: "ko", newTarget: "ko", oldProvider: "apple", newProvider: "deepl")
                  && liveTranslatorNeedsRebuild(oldTarget: "ko", newTarget: "en", oldProvider: "apple", newProvider: "apple")
                  && !liveTranslatorNeedsRebuild(oldTarget: "ko", newTarget: "ko", oldProvider: "deepl", newProvider: "deepl"))
            // Settings provider popup: values (saved) and titles (shown) both derive from the enum in the
            // same order, so Save can't persist a rawValue that doesn't match what the user picked.
            check("settings: translation provider popup values match the enum, in order",
                  TranslationProvider.allCases.map(\.rawValue) == ["apple", "deepl"]
                  && TranslationProvider.allCases.map(\.title).allSatisfy { !$0.isEmpty })
            // Interpretation pipeline (Decorator stages, pluggable TTS). Speak a final translation ONCE;
            // never a partial, never an untranslated line, never twice — and always forward downstream so
            // the overlay still renders. The TTS backend is a protocol so a cloud voice drops in later.
            check("interpret: speak a final translation once, not partials/dupes",
                  shouldSpeakInterpretation(isFinal: true, hasTranslation: true, alreadySpoken: false)
                  && !shouldSpeakInterpretation(isFinal: false, hasTranslation: true, alreadySpoken: false)   // partial
                  && !shouldSpeakInterpretation(isFinal: true, hasTranslation: false, alreadySpoken: false)   // not translated yet
                  && !shouldSpeakInterpretation(isFinal: true, hasTranslation: true, alreadySpoken: true))    // already spoken
            check("interpret: TTS provider enum is pluggable (apple on-device now)",
                  TTSProvider.allCases.map(\.rawValue) == ["apple"] && TTSProvider.apple.isReady && TTSProvider.current == .apple)
            final class RecordingSynth: SpeechSynthesizing { var said: [(String, String)] = []
                func speak(_ t: String, lang: String) { said.append((t, lang)) }; func stopSpeaking() {} }
            final class CountingSink: UtteranceSink { var count = 0; func receive(_ u: Utterance) { count += 1 } }
            let synth = RecordingSynth(); let downstream = CountingSink()
            let speak = SpeakingStage(tts: synth, next: downstream)
            let uid = UUID()
            speak.receive(Utterance(id: uid, speaker: "me", sourceText: "안녕", sourceLang: "ko", isFinal: false, translation: nil, targetLang: "ja"))
            speak.receive(Utterance(id: uid, speaker: "me", sourceText: "안녕하세요", sourceLang: "ko", isFinal: true, translation: "こんにちは", targetLang: "ja"))
            speak.receive(Utterance(id: uid, speaker: "me", sourceText: "안녕하세요", sourceLang: "ko", isFinal: true, translation: "こんにちは", targetLang: "ja"))
            check("interpret: SpeakingStage speaks once + always forwards to the next stage",
                  synth.said.count == 1 && synth.said.first?.0 == "こんにちは" && synth.said.first?.1 == "ja" && downstream.count == 3)
            // Saved-transcript scaffold localization: language-selected labels, and the old workflow
            // footer must never come back.
            let tDoc = TranscriptDoc(title: "T", day: "2026-07-05", hmStart: "10:00", hmEnd: "11:00", mins: 60,
                                     micVoiced: 1.0, sysVoiced: 2.0, modelName: "m.bin",
                                     audioLine: "- x", meta: "", excludes: "com.spotify.client",
                                     bodyMine: "나", bodyTheirs: "상대", body: "hello")
            let mdKo = tDoc.markdown(.forLanguage("ko")), mdEn = tDoc.markdown(.forLanguage("en")), mdJa = tDoc.markdown(.forLanguage("ja"))
            check("transcript md: section localized",
                  mdKo.contains("## 전사 (transcript)") && mdEn.contains("## Transcript") && mdJa.contains("## 文字起こし"))
            check("transcript md: labels localized",
                  mdKo.contains("- 시각:") && mdEn.contains("- Time:") && mdJa.contains("- 時刻:") && mdEn.contains("(60 min)"))
            check("transcript md: note keeps BODY speaker labels",
                  mdEn.contains("나 = microphone") && mdEn.contains("Excluded: com.spotify.client"))
            check("transcript md: workflow footer removed",
                  !mdKo.contains("자동 생성") && !mdKo.contains("topics/") && !mdEn.contains("topics/"))
            check("transcript l10n: failure + unknown lang fallback",
                  TranscriptL10n.forLanguage("ko").failureNote(model: "m").contains("전사 실패")
                  && TranscriptL10n.forLanguage("fr").section == "## Transcript"
                  && TranscriptL10n.forLanguage(nil).section == "## Transcript")
            // Post-process invocation builder — the built-in summary templates and the freeform mode.
            func inv(_ m: PostProcessMode, _ r: SummaryRunner, prompt: String = "P", shell: String = "", out: String = "") -> String? {
                postProcessInvocation(mode: m, runner: r, prompt: prompt, shellCmd: shell,
                                      transcriptPath: "/t/a b's.md", outDir: out)
            }
            check("post-process: off → nil, shell empty → nil",
                  inv(.off, .claude) == nil && inv(.shell, .claude) == nil)
            check("post-process: shell appends quoted path",
                  inv(.shell, .claude, shell: "./x.sh") == "./x.sh '/t/a b'\\''s.md'")
            check("post-process: claude summary template (mkdir + .partial promote)",
                  inv(.summary, .claude) == "mkdir -p '/t' && claude -p 'P' < '/t/a b'\\''s.md' "
                                          + "> '/t/a b'\\''s-sum.md.partial' "
                                          + "&& mv '/t/a b'\\''s-sum.md.partial' '/t/a b'\\''s-sum.md'")
            check("post-process: gemini summary template",
                  inv(.summary, .gemini)?.contains("gemini -p 'P'") == true)
            check("post-process: codex pipes prompt+transcript via stdin",
                  inv(.summary, .codex)?.contains("| codex exec -") == true)
            // v1→v2 migration: an unset mode with a v1 command must run as .shell (upgrades must not
            // silently kill an existing pipeline); explicit modes always win.
            check("post-process: v1 hook migrates to shell mode",
                  effectivePostProcessMode(rawMode: "", shellCmd: "./x.sh") == .shell
                  && effectivePostProcessMode(rawMode: "", shellCmd: " ") == .off
                  && effectivePostProcessMode(rawMode: "off", shellCmd: "./x.sh") == .off
                  && effectivePostProcessMode(rawMode: "summary", shellCmd: "./x.sh") == .summary)
            // Prompt file: readable file overrides inline; blank/missing file falls back (logged).
            let pfURL = FileManager.default.temporaryDirectory.appendingPathComponent("macrec-prompt-\(UUID().uuidString).md")
            try? "  file prompt\n".write(to: pfURL, atomically: true, encoding: .utf8)
            check("post-process: prompt file overrides inline (trimmed) + fallback",
                  effectiveSummaryPrompt(inline: "inline", filePath: pfURL.path) == "file prompt"
                  && effectiveSummaryPrompt(inline: "inline", filePath: "/nonexistent/p.md") == "inline"
                  && effectiveSummaryPrompt(inline: "inline", filePath: " ") == "inline")
            try? FileManager.default.removeItem(at: pfURL)
            check("post-process: empty prompt falls back to the built-in default",
                  inv(.summary, .claude, prompt: " ")?.contains(defaultSummaryPrompt.prefix(25)) == true)
            check("post-process: summary path derivation (custom dir + tilde)",
                  summaryOutputPath(transcriptPath: "/t/2026-07-07-1000.md", outDir: "") == "/t/2026-07-07-1000-sum.md"
                  && summaryOutputPath(transcriptPath: "/t/2026-07-07-1000-standup.md", outDir: "~/sums")
                     == (("~/sums" as NSString).expandingTildeInPath + "/2026-07/2026-07-07-1000-standup.md")
                  && summaryOutputPath(transcriptPath: "/t/undated-note.md", outDir: "/s")
                     == "/s/undated-note.md")   // no date prefix → no month folder
            // The runner really executes — quoting-hostile path (space + apostrophe) via the shell mode.
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent("macrec hook's \(UUID().uuidString)")
            let markerCmd = postProcessInvocation(mode: .shell, runner: .claude, prompt: "", shellCmd: "touch",
                                                  transcriptPath: marker.path, outDir: "")
            var hookExit: Int32 = -99
            let hookSem = DispatchSemaphore(value: 0)
            runPostProcessCommand(markerCmd ?? "") { code in hookExit = code; hookSem.signal() }
            let hookDone = hookSem.wait(timeout: .now() + 10) == .success
            check("post-process: runner executes with a quoting-safe path",
                  hookDone && hookExit == 0 && FileManager.default.fileExists(atPath: marker.path))
            try? FileManager.default.removeItem(at: marker)
            // Empty command = off: completion must never fire.
            var fired = false
            runPostProcessCommand("   ") { _ in fired = true }
            Thread.sleep(forTimeInterval: 0.2)
            check("post-process: empty command is a no-op", !fired)
            // Settings layout regression (user-reported): a tab taller than the window CLIPPED its rows
            // (Post-process settings were unreachable). Every pane must host its grid in a scroll view,
            // and Post-process must be its own tab. Headless: builds the real form, no window shown.
            let sw = SettingsWindowController(onSave: {})
            let panes = sw.panesForTest
            check("settings: panes built for inspection", !panes.isEmpty)
            check("settings: General pane comes first", panes.first?.title == "General")
            // AUTOMATED UI TEST: lay out every pane at a real size and assert nothing is collapsed
            // or overlapping. This fails the build on visual breakage (the NSBox "card" redesign
            // floated its grids so controls overlapped and shipped destroyed — a structural-only
            // check passed it). Run `macrec settings-snapshot <dir>` to also eyeball the PNGs.
            let layoutIssues = sw.paneLayoutIssues()
            if !layoutIssues.isEmpty { for m in layoutIssues.prefix(8) { print("   layout: \(m)") } }
            check("settings: no pane control is collapsed or overlapping (\(layoutIssues.count) issues)",
                  layoutIssues.isEmpty)
            check("settings: every pane scrolls (rows can never be clipped away)",
                  panes.allSatisfy { p in p.view.subviews.contains { ($0 as? NSScrollView)?.documentView != nil } })
            check("settings: Summaries and Schedule are their own panes",
                  panes.contains { $0.title == "Summaries" } && panes.contains { $0.title == "Schedule" })
            check("settings: Recording split into Recording + Storage panes",
                  panes.contains { $0.title == "Recording" } && panes.contains { $0.title == "Storage" })
            // Grouped row-card structure: every pane renders at least one rounded SectionCard, and
            // no card is empty (a section with no rows would draw a stray hairline box).
            func allCards(in view: NSView) -> [SectionCard] {
                var out: [SectionCard] = []
                if let c = view as? SectionCard { out.append(c) }
                if let sv = view as? NSScrollView, let d = sv.documentView { out += allCards(in: d) }
                for sub in view.subviews { out += allCards(in: sub) }
                return out
            }
            var cardCount = 0
            var everyPaneHasCard = true
            var noEmptyCard = true
            for p in panes {
                let cards = allCards(in: p.view)
                cardCount += cards.count
                if cards.isEmpty { everyPaneHasCard = false }
                for c in cards {
                    // A card wraps a single vertical stack of rows; an empty stack = a bug.
                    let rows = (c.subviews.first as? NSStackView)?.arrangedSubviews ?? []
                    if rows.isEmpty { noEmptyCard = false }
                }
            }
            check("settings: every pane renders at least one section card",
                  cardCount >= panes.count && everyPaneHasCard)
            check("settings: no section card is empty", noEmptyCard)
            // Sidebar search: pane content (not just titles) is the index — "prompt" finds
            // Summaries, junk finds nothing, empty shows everything in order.
            check("settings: sidebar search matches pane content",
                  settingsSearchHits(query: "prompt", index: panes.map { $0.searchText })
                      .contains(panes.firstIndex { $0.title == "Summaries" } ?? -1)
                  && settingsSearchHits(query: "", index: panes.map { $0.searchText }) == Array(panes.indices)
                  && settingsSearchHits(query: "zzxqy", index: panes.map { $0.searchText }).isEmpty
                  && settingsSearchHits(query: "API KEY", index: panes.map { $0.searchText })
                      .contains(panes.firstIndex { $0.title == "Live Captions" } ?? -1))
            // Edit shortcuts in the Settings window (LSUIElement app has no Edit menu — ⌘V into a
            // field once did nothing, user-reported). The window routes these action selectors to
            // the field editor; the mapping is pure and checked here.
            check("settings: ⌘V/⌘C/⌘X/⌘A map to the standard edit actions",
                  standardEditSelector(key: "v", flags: .command) == #selector(NSText.paste(_:))
                  && standardEditSelector(key: "c", flags: .command) == #selector(NSText.copy(_:))
                  && standardEditSelector(key: "x", flags: .command) == #selector(NSText.cut(_:))
                  && standardEditSelector(key: "a", flags: .command) == #selector(NSResponder.selectAll(_:)))
            check("settings: ⌘Z undo, ⌘⇧Z redo, plain V ignored, ⌘⌥V not hijacked",
                  standardEditSelector(key: "z", flags: .command) == Selector(("undo:"))
                  && standardEditSelector(key: "z", flags: [.command, .shift]) == Selector(("redo:"))
                  && standardEditSelector(key: "v", flags: []) == nil
                  && standardEditSelector(key: "v", flags: [.command, .option]) == nil)
            // Schedule pickers (days multi-select + time-range rows) must round-trip through the SAME
            // string prefs the engine parses — seed the UI, read it back, and confirm it parses to the
            // identical RecordSchedule (no meaning lost when we swapped text fields for pickers).
            sw.loadScheduleUI(days: "mon,wed,fri", hours: "10:00-12:00, 13:00-19:00")
            let rtDays = sw.serializeDays(), rtHours = sw.serializeHours()
            check("settings: schedule pickers round-trip to the engine's format",
                  RecordSchedule.parseDays(rtDays) == RecordSchedule.parseDays("mon,wed,fri")
                  && RecordSchedule.parseRanges(rtHours).map { [$0.start, $0.end] }
                     == RecordSchedule.parseRanges("10:00-12:00, 13:00-19:00").map { [$0.start, $0.end] })
            sw.loadScheduleUI(days: "", hours: "")   // empty = every day / all hours
            check("settings: empty schedule serializes empty (every day, all hours)",
                  sw.serializeDays().isEmpty && sw.serializeHours().isEmpty)
            // Nested-scroll passthrough: the pane must still scroll with the pointer over a prompt box.
            // A prompt/calendar box
            // whose content FITS must hand the wheel to the pane; one that OVERFLOWS keeps it to scroll
            // itself. The prompt editor is ~84pt tall — text that fits passes through, long text doesn't.
            check("settings: nested scroll passes wheel to pane when its content fits",
                  nestedScrollPassesThrough(contentHeight: 84, clipHeight: 84)          // exact fit → pass
                  && nestedScrollPassesThrough(contentHeight: 40, clipHeight: 84)       // smaller → pass
                  && !nestedScrollPassesThrough(contentHeight: 400, clipHeight: 84)     // overflow → keep
                  && !nestedScrollPassesThrough(contentHeight: 85, clipHeight: 84))     // just over → keep
            // The embedded editors/lists are actually PassthroughScrollViews in the built tree (prompt,
            // daily-prompt, calendar) — so the fix is wired, not just declared.
            check("settings: embedded editors use the passthrough scroll view",
                  sw.passthroughScrollCountForTest >= 2)
            // Tray Pause/Resume enablement: Pause greys out when nothing is recording (off-hours/idle);
            // Resume stays clickable while paused.
            check("tray: Pause enabled recording; Resume enabled when paused OR schedule-paused; greyed only when truly idle",
                  pauseItemEnabled(paused: false, schedulePaused: false, hasEngine: true)       // recording → can Pause
                  && !pauseItemEnabled(paused: false, schedulePaused: false, hasEngine: false)  // truly idle → greyed
                  && pauseItemEnabled(paused: true, schedulePaused: false, hasEngine: false)    // manual pause → can Resume
                  && pauseItemEnabled(paused: false, schedulePaused: true, hasEngine: false)    // schedule off-hours → can Resume (the fix)
                  && pauseItemEnabled(paused: true, schedulePaused: true, hasEngine: true))
            // Every "Choose…" folder button is bound to a handler the controller implements — guards
            // against a picker wired to nothing / a renamed selector (user: Storage "Choose…" did nothing).
            let chooseWired = sw.chooseButtonsWiredForTest
            check("settings: every Choose… button is wired to a real handler (\(chooseWired.count) found)",
                  chooseWired.count >= 7 && chooseWired.allWired)
            // An NSSwitch carries no title, so its row name has to be attached as an accessibility label
            // or VoiceOver reads an anonymous button where a named setting used to be.
            check("settings: every switch announces its setting name to VoiceOver",
                  sw.unlabeledSwitchesForTest == 0)
            // The footer: "Save" (default) applies in place, "Close" (Esc) leaves. Guards the wiring —
            // a renamed selector here silently turns Save into a dead button.
            let footer = sw.footerButtonsForTest
            check("settings: footer is Close + Save, both wired (Save no longer closes the window)",
                  footer.map(\.title) == ["Close", "Save"]
                  && footer.allSatisfy { b in (b.target as? NSObject)?.responds(to: b.action ?? Selector("")) == true }
                  && footer.last?.keyEquivalent == "\r" && footer.first?.keyEquivalent == "\u{1b}")
            // The overlay's engine picker must never offer an engine that can't run: Deepgram sat in the
            // list with no API key and answered a click with an error line where captions belong.
            // Apple is the floor — switching everything off must not leave an empty picker.
            let noKeys: (LiveEngine) -> Bool = { $0 == .apple || $0 == .whisper }
            check("live: the engine picker offers only engines that are ON and READY (never empty)",
                  selectableLiveEngines(LiveEngine.allCases, ready: noKeys, enabled: { _ in true }) == [.apple, .whisper]
                  && selectableLiveEngines(LiveEngine.allCases, ready: { _ in true },
                                           enabled: { $0 != .apple }) == [.whisper, .deepgram, .openai, .gladia, .elevenlabs]
                  && selectableLiveEngines(LiveEngine.allCases, ready: noKeys,
                                           enabled: { $0 != .apple && $0 != .whisper }) == [.apple]
                  && selectableLiveEngines(LiveEngine.allCases, ready: { _ in false }, enabled: { _ in false }) == [.apple])
            // The opacity slider fades the BACKGROUND. Fading the window faded the captions with it —
            // at 0.3 the overlay showed nothing at all, which is the one thing it exists to show.
            // Zero is a legal, useful setting — the closed-caption look. Only out-of-range values clamp.
            // Contrast goes BEHIND the glyphs, never into them: a halo smeared them, a stroke thickened
            // them. And only when the backdrop is too faint to carry the contrast itself.
            // A subtitle leads with the TRANSLATION — that is the line you read; the original is a
            // whisper above it. With nothing to translate, the original is the subtitle.
            check("live: a subtitle leads with the translation and demotes the original",
                  subtitleLine(original: "会議を始めましょう。", translated: "회의를 시작합시다.")
                  == ("회의를 시작합시다.", "会議を始めましょう。")
                  && subtitleLine(original: "Let's begin.", translated: nil) == ("Let's begin.", nil)
                  && subtitleLine(original: "Let's begin.", translated: "  ") == ("Let's begin.", nil)
                  && subtitleLine(original: "", translated: "회의") == ("회의", nil))
            // Read at a glance, not squinted at; and a film shows one utterance, not a scrolling wall.
            check("live: a subtitle is larger than the log's body text and shows at most two lines",
                  subtitleFontSize(14) == 20 && subtitleFontSize(9) == 18 && subtitleMaxLines == 2)
            // A transparent LOG keeps an outline so it still reads as a grabbable window; a subtitle must
            // not have one — a rectangle drawn around a film subtitle is what breaks the illusion.
            check("live: the window outline is drawn for the log view and never for a subtitle",
                  captionEdgeVisible(subtitle: false) && !captionEdgeVisible(subtitle: true))
            check("live: captions get a backplate only when the backdrop is too faint to carry contrast",
                  captionTextNeedsBackplate(backdropAlpha: 0.0)
                  && captionTextNeedsBackplate(backdropAlpha: 0.55)
                  && !captionTextNeedsBackplate(backdropAlpha: 0.6)
                  && !captionTextNeedsBackplate(backdropAlpha: 1.0))
            check("live: overlay opacity spans a fully transparent backdrop to a fully opaque one",
                  captionBackdropAlpha(0.0) == 0.0 && captionBackdropAlpha(1.0) == 1.0
                  && captionBackdropAlpha(0.3) == 0.3
                  && captionBackdropAlpha(-1) == 0.0 && captionBackdropAlpha(9.9) == 1.0)
            // Drive the real window: at the slider's low end ONLY the backdrop may be translucent.
            // Window alpha would multiply into every subview, which is exactly how the captions vanished.
            if #available(macOS 26, *) {
                let cw = LiveCaptionWindow(onClose: {}, onReconfigure: {}, onRestyle: {})
                let before = cw.captionAlphasForTest
                cw.setOpacityForTest(0.0)   // the extreme: background gone, captions must not follow it
                let after = cw.captionAlphasForTest
                check("live: at a fully transparent backdrop the window and the captions stay opaque",
                      before.window == 1 && before.text == 1
                      && after.window == 1 && after.text == 1 && after.backdrop == 0.0)
                // The alpha assertion above passed while the overlay rendered as an EMPTY see-through
                // window (a .behindWindow material ignores the view's alpha). Assert the fill exists.
                check("live: the overlay backdrop actually paints, sized to the content, beneath the captions",
                      cw.backdropPaintsForTest)
                // caption-snapshot renders offscreen. That only tells the truth while nothing in the panel
                // is composited by the window server — so assert the render is not blank, and that the
                // blank-detector would have caught the old failure.
                cw.renderSampleCaptions()
                cw.setOpacityForTest(0.0)   // the transparent end, where the captions used to disappear
                let shot = cw.renderContentForTest()
                let emptyRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB,
                                               bytesPerRow: 0, bitsPerPixel: 0)!
                check("live: the overlay renders offscreen with visible captions, and a blank render is caught",
                      shot != nil && !snapshotIsBlank(shot!)
                      && snapshotIsBlank(emptyRep))   // the guard that stops a reassuring, empty PNG
                // …and nothing paints BEHIND it that the slider can't reach: `.hudWindow` slipped its own
                // full-window material into the theme frame, so the overlay never went fully transparent.
                check("live: no window-chrome material sits behind the backdrop (fully transparent is reachable)",
                      cw.nothingPaintsBehindBackdropForTest)
                // With the background gone the panel loses every edge; the outline must not fade with it,
                // and must not steal the clicks that select text or drag the window.
                let e = cw.edgeSurvivesForTest
                check("live: the outline survives a fully transparent backdrop and never eats the mouse",
                      e.visible && e.ignoresMouse)
                // The picker was built once at window creation: an engine switched off in Settings stayed
                // in the menu until the overlay was reopened. Assert it re-reads the ON list — never that
                // a particular engine is installed. `isReady` probes the filesystem and the Keychain, and
                // CI has neither whisper-cli nor its model, so pinning `[.whisper]` made this machine-dependent.
                // Assert it RE-READS the ON list. Which engines are *ready* depends on the machine —
                // `isReady` probes the filesystem, the Keychain and MR_*_KEY env vars — so the only thing
                // this can pin is that a saved change is picked up without reopening the overlay. What
                // gets picked from a given (ready, enabled) pair is `selectableLiveEngines`, tested purely.
                Pref.d.set([LiveEngine.apple.rawValue], forKey: Pref.liveEnginesOn)
                cw.reloadEngineChoices()
                let appleOnly = cw.engineChoicesForTest
                Pref.d.set(LiveEngine.allCases.map(\.rawValue), forKey: Pref.liveEnginesOn)
                cw.reloadEngineChoices()
                let allOn = cw.engineChoicesForTest
                Pref.d.removeObject(forKey: Pref.liveEnginesOn)
                check("live: reloadEngineChoices re-reads Settings instead of staying frozen at window creation",
                      appleOnly == [.apple]                       // the ON list narrows the menu…
                      && allOn.count >= appleOnly.count           // …and widening it re-reads, not caches
                      && allOn.first == .apple                    // order follows allCases, apple first
                      && !allOn.isEmpty)                          // never strands the user
            }
            // The harness drives the real UI, which persists as it goes: `caption-snapshot` left the user
            // in subtitle mode at zero opacity, and the next selftest read that back and failed. A test
            // subcommand must not be able to change the app's settings.
            // A pane taller than the window used to be cropped at the fold — the bottom of Summaries and
            // the whole Gladia section had never been rendered. The window grows to the document height,
            // floored at the runtime size and capped so a runaway pane can't produce an unopenable PNG.
            check("settings: a snapshot grows to the pane's full height, floored and capped",
                  snapshotContentHeight(runtime: 600, document: 900) == 900       // taller pane → grow
                  && snapshotContentHeight(runtime: 600, document: 400) == 600    // short pane → runtime floor
                  && snapshotContentHeight(runtime: 600, document: 9999) == 4000) // runaway → capped
            check("prefs: the test harness writes to a throwaway suite, never the user's",
                  Pref.suiteName == "com.ikhoon.macrec.prefs"     // the real one, still named here…
                  && Pref.d.value(forKey: "__probe__") == nil)    // …but not the store the harness holds
            Pref.d.set("dirty", forKey: "__probe__")
            let realStore = UserDefaults(suiteName: Pref.suiteName)
            check("prefs: a write from the harness never reaches the user's suite",
                  Pref.d.string(forKey: "__probe__") == "dirty"
                  && realStore?.string(forKey: "__probe__") == nil)
            Pref.d.removeObject(forKey: "__probe__")

            // The harness must never read the user's real credentials, and every read is an authorization
            // check — an unsigned dev build turns each one into a password prompt.
            _ = Keychain.get("deepgram"); _ = Keychain.get("deepgram"); _ = Keychain.get("openai")
            check("keychain: the test harness never touches the real Keychain",
                  Keychain.disabled && Keychain.readsForTest == 0 && Keychain.get("deepgram") == nil)
            // Asking whether an engine is READY must never ask for a SECRET — that is the authorization
            // prompt. Presence is answered by an attributes-only probe that hands nothing back.
            let secretsBefore = Keychain.secretRequestsForTest
            _ = LiveEngine.deepgram.isReady
            _ = LiveEngine.openai.isReady
            _ = selectableLiveEngines(LiveEngine.allCases, ready: { $0.isReady }, enabled: { $0.isEnabled })
            _ = sw.loadForTest()
            check("keychain: engine readiness and opening Settings request no secrets",
                  Keychain.secretRequestsForTest == secretsBefore
                  && sw.keyFieldsForTest.allSatisfy { $0.isEmpty || $0 == SettingsWindowController.keyMask })
            // MR_KEYCHAIN_ROUNDTRIP=1 drives the REAL Keychain against a throwaway account. It writes,
            // reads back, overwrites and deletes — proving `set` recreates the item (SecItemUpdate leaves
            // the creating process's ACL in place, which is how a credential ends up asking the wrong
            // binary for permission forever). Off by default: the harness must not touch credentials.
            if ProcessInfo.processInfo.environment["MR_KEYCHAIN_ROUNDTRIP"] == "1" {
                let acct = "selftest-roundtrip"
                Keychain.disabled = false
                Keychain.forgetCacheForTest()
                _ = Keychain.set(acct, "")                       // start clean
                let absent = !Keychain.exists(acct) && Keychain.get(acct) == nil
                let wrote = Keychain.set(acct, "first")
                Keychain.forgetCacheForTest()
                let readBack = Keychain.get(acct) == "first" && Keychain.exists(acct)
                let rewrote = Keychain.set(acct, "second")
                Keychain.forgetCacheForTest()
                let reread = Keychain.get(acct) == "second"
                _ = Keychain.set(acct, "")
                Keychain.forgetCacheForTest()
                let gone = !Keychain.exists(acct)
                Keychain.disabled = true
                check("keychain: real round-trip — write, read, recreate on overwrite, delete",
                      absent && wrote && readBack && rewrote && reread && gone)
            }
            // A switch on + no key used to be silent: the engine simply never showed up in the picker.
            check("live: an engine switched on without its credential is reported, not silently dropped",
                  enginesMissingCredentials(LiveEngine.allCases, enabled: { $0 == .deepgram || $0 == .apple },
                                            ready: { $0 == .apple }) == [.deepgram]
                  && enginesMissingCredentials(LiveEngine.allCases, enabled: { _ in true }, ready: { _ in true }).isEmpty
                  && enginesMissingCredentials(LiveEngine.allCases, enabled: { _ in false }, ready: { _ in false }).isEmpty)
            // The DeepL translation provider joins that same "you turned it on without a key" warning —
            // it used to save silently and just fall back to Apple. Engines + provider in one list.
            check("live: DeepL selected without a key is reported alongside missing-key engines",
                  missingCredentialLabels(engines: [], engineEnabled: { _ in false }, engineReady: { _ in false },
                                          translationProvider: .deepl, deeplReady: false) == ["DeepL translation"]
                  && missingCredentialLabels(engines: [], engineEnabled: { _ in false }, engineReady: { _ in false },
                                             translationProvider: .deepl, deeplReady: true).isEmpty     // key present → fine
                  && missingCredentialLabels(engines: [], engineEnabled: { _ in false }, engineReady: { _ in false },
                                             translationProvider: .apple, deeplReady: false).isEmpty)   // Apple needs no key
            // Indexing allCases picked the wrong engine as soon as one was filtered out of the menu.
            check("live: a popup index maps into the FILTERED list, never into allCases",
                  engineAtPopupIndex(1, choices: [.whisper, .deepgram, .openai, .gladia]) == .deepgram
                  && engineAtPopupIndex(0, choices: [.deepgram]) == .deepgram
                  && engineAtPopupIndex(99, choices: [.apple, .whisper]) == .whisper   // clamped, not a crash
                  && engineAtPopupIndex(0, choices: []) == nil)
            // Turning cloud engines off by default must not silently downgrade someone already on one.
            check("live: an absent ON-list keeps on-device engines and grandfathers the engine already in use",
                  liveEngineEnabled(.apple, storedOn: nil, selectedEngine: nil)
                  && liveEngineEnabled(.whisper, storedOn: nil, selectedEngine: nil)
                  && !liveEngineEnabled(.deepgram, storedOn: nil, selectedEngine: nil)
                  && liveEngineEnabled(.deepgram, storedOn: nil, selectedEngine: "deepgram")   // the upgrade path
                  && liveEngineEnabled(.deepgram, storedOn: ["deepgram"], selectedEngine: nil)
                  && !liveEngineEnabled(.apple, storedOn: ["deepgram"], selectedEngine: "apple"))
            // ⌘V into a Settings field only works because the window is an EditableWindow — an LSUIElement
            // app has no Edit menu, so a plain NSWindow drops the key equivalent on the floor.
            check("settings: the window is an EditableWindow (⌘V/⌘C/⌘X/⌘A reach the field editor)",
                  sw.window is EditableWindow)
            // Restarting the recorder discards the in-progress segment. Save must only do that when a
            // setting the recorder actually reads changed — Return in any text field fires Save now.
            let fpA = engineFingerprint(["voiceMin": "5", "exclude": "com.spotify.client"])
            check("settings: the engine fingerprint changes iff an engine-affecting pref changed",
                  fpA == engineFingerprint(["exclude": "com.spotify.client", "voiceMin": "5"])   // order-independent
                  && fpA != engineFingerprint(["voiceMin": "3", "exclude": "com.spotify.client"])
                  && !SettingsWindowController.engineKeysForTest.contains(Pref.liveEnginesOn)
                  && !SettingsWindowController.engineKeysForTest.contains(Pref.dailyDigestName))
            // Every pref that must make Save restart the recorder. Omitting one means the setting saves
            // and nothing happens — turning the schedule OFF left the engine parked off-hours, because
            // only restartEngine() clears `schedulePaused` and re-baselines the schedule.
            let mustRestart = [Pref.schedEnabled, Pref.schedDays, Pref.schedHours, Pref.segment, Pref.model,
                               Pref.customModel, Pref.lang, Pref.exclude, Pref.txtDir, Pref.audioDir,
                               Pref.systemAudio, Pref.echoReduce, Pref.vad, Pref.keepAudio, Pref.voiceMin,
                               Pref.cal, Pref.calendars, Pref.hintsTerms, Pref.hintsFile, Pref.hintsCalendar]
            check("settings: every recorder-affecting pref (schedule included) forces an engine restart on Save",
                  mustRestart.allSatisfy { SettingsWindowController.engineKeysForTest.contains($0) })
            // The echo canceller must be fed the FULL speaker mix, not the transcript's filtered one — an
            // excluded app (Spotify) still plays out loud and bleeds into the mic, so a reference missing
            // it can never cancel that bleed. The dedicated full-mix reference tap is stood up only when
            // echo reduction is on AND something is excluded (with nothing excluded the filtered tap already
            // IS the full mix). This is the exact guard CaptureSession.startReferenceTap uses.
            check("aec: stand up the full-mix reference tap only when echo reduction is on AND apps are excluded",
                  shouldStartReferenceTap(echoReduceEnabled: true,  hasExcludedApps: true)   // the one case that needs it
                  && !shouldStartReferenceTap(echoReduceEnabled: true,  hasExcludedApps: false) // nothing excluded → filtered IS full
                  && !shouldStartReferenceTap(echoReduceEnabled: false, hasExcludedApps: true)  // AEC off → moot
                  && !shouldStartReferenceTap(echoReduceEnabled: false, hasExcludedApps: false))
            // System-audio exclusion: match on Core Audio's own process list, so a helper process that
            // plays under its own bundle id is at least VISIBLE (AppKit's app lookup never saw it), and
            // notice when a relaunch (new object id) has made the live tap's frozen exclusion set stale.
            let procs = [AudioProcessInfo(objectID: 501, bundleID: "com.spotify.client"),
                         AudioProcessInfo(objectID: 502, bundleID: "com.spotify.client.helper"),
                         AudioProcessInfo(objectID: 503, bundleID: nil)]
            check("audio: exclusion matches Core Audio's bundle ids; unattributed processes are never excluded",
                  matchExcludedProcesses(procs, excludeBundleIds: ["com.spotify.client"]) == [501]
                  && matchExcludedProcesses(procs, excludeBundleIds: ["com.spotify.client", "com.spotify.client.helper"]) == [501, 502]
                  && matchExcludedProcesses(procs, excludeBundleIds: []).isEmpty)
            check("audio: a relaunched excluded app (new object id) makes the live tap's exclusion stale",
                  tapExclusionIsStale(current: [222], live: [111])          // relaunch — the reported bug
                  && tapExclusionIsStale(current: [111], live: [])          // launched after the tap was built
                  && !tapExclusionIsStale(current: [111, 222], live: [222, 111]))   // same set, any order
            // Sidebar selection is app state, not focus state: the accent pill must survive AppKit
            // clearing isEmphasized when focus moves to a text field (it looked like a random blue blink).
            let sidebarRow = SidebarRowView()
            sidebarRow.isEmphasized = false
            check("settings: sidebar selection stays accent-filled when the table loses focus",
                  sidebarRow.isEmphasized)
            // Click/label/enablement all route through togglePauseShouldResume — test the REAL decision
            // the bug lived in (togglePause resumed only `if paused`, ignoring schedule-pause).
            check("tray: schedule-paused resumes on click (the bug), manual-pause resumes, idle does not",
                  togglePauseShouldResume(paused: false, schedulePaused: true)      // off-hours → Resume (the fix)
                  && togglePauseShouldResume(paused: true, schedulePaused: false)   // manual pause → Resume
                  && !togglePauseShouldResume(paused: false, schedulePaused: false))// recording/idle → Pause
            // Grant item hides only once BOTH capture grants are in (calendar excluded on purpose).
            check("tray: Grant permissions hidden only when audio AND mic granted",
                  captureGrantsSatisfied(audioGranted: true, micGranted: true)
                  && !captureGrantsSatisfied(audioGranted: false, micGranted: true)
                  && !captureGrantsSatisfied(audioGranted: true, micGranted: false))
            // Choose… presents as a SHEET on a visible window (bare runModal opens behind on an
            // .accessory app — the "Choose did nothing" bug); no visible window → activate + runModal.
            check("settings: dir picker uses a sheet iff there is a visible window",
                  dirPickerPresentation(hasVisibleWindow: true) == .sheet
                  && dirPickerPresentation(hasVisibleWindow: false) == .activateAndRunModal)
            // Update-alert Open URL: none for brew; https release URL otherwise; a non-https scheme or a
            // blank/missing API url falls back to the https releases page — never opens an unsafe scheme.
            check("update alert: brew→no button; https htmlURL→that exact link; http/non-https/blank→https releases fallback; unsafe releases→nil",
                  updateAlertOpenURL(installedViaBrew: true, htmlURL: "https://x/y", releasesURL: UpdateChecker.releasesURL) == nil
                  && updateAlertOpenURL(installedViaBrew: false, htmlURL: "https://github.com/ikhoon/macrec/releases/tag/v9", releasesURL: UpdateChecker.releasesURL)?.absoluteString == "https://github.com/ikhoon/macrec/releases/tag/v9"
                  && updateAlertOpenURL(installedViaBrew: false, htmlURL: "http://x/y", releasesURL: UpdateChecker.releasesURL)?.absoluteString == UpdateChecker.releasesURL
                  && updateAlertOpenURL(installedViaBrew: false, htmlURL: "javascript:alert(1)", releasesURL: UpdateChecker.releasesURL)?.absoluteString == UpdateChecker.releasesURL
                  && updateAlertOpenURL(installedViaBrew: false, htmlURL: "", releasesURL: UpdateChecker.releasesURL)?.absoluteString == UpdateChecker.releasesURL
                  && updateAlertOpenURL(installedViaBrew: false, htmlURL: nil, releasesURL: "file:///etc/passwd") == nil)
            // The menu-bar brand mark actually draws in every state (not an all-transparent image — the
            // "structurally valid but visually destroyed" class of bug). LOOK via `macrec icon-snapshot`.
            check("tray icon: brand mark renders content (recording, recording+voice, paused)",
                  brandMarkHasContent(recording: true, voice: true)
                  && brandMarkHasContent(recording: true, voice: false)
                  && brandMarkHasContent(recording: false, voice: false))
            // Short-blip filter: no overlapping meeting + under 3 min of speech → no file (user rule).
            check("keep transcript: meeting always kept; no meeting needs ≥3 min speech",
                  shouldKeepTranscript(hasMeeting: true, speechSeconds: 5)
                  && shouldKeepTranscript(hasMeeting: false, speechSeconds: 180)
                  && shouldKeepTranscript(hasMeeting: false, speechSeconds: 240)
                  && !shouldKeepTranscript(hasMeeting: false, speechSeconds: 179)
                  && !shouldKeepTranscript(hasMeeting: false, speechSeconds: 0))
            // Summaries Mode is a real TAB — it SHOWS only the selected mode's sections (not readonly
            // greying). Switch each mode and confirm only that group is visible.
            sw.setPPModeForTest("summary")
            check("summaries tab: Automatic summary shown, Custom command + off hidden",
                  sw.ppGroupVisibleForTest("pp.summary")
                  && !sw.ppGroupVisibleForTest("pp.shell") && !sw.ppGroupVisibleForTest("pp.off"))
            sw.setPPModeForTest("shell")
            check("summaries tab: Custom command shown, Automatic summary hidden",
                  sw.ppGroupVisibleForTest("pp.shell") && !sw.ppGroupVisibleForTest("pp.summary"))
            sw.setPPModeForTest("off")
            check("summaries tab: off note shown, both mode sections hidden",
                  sw.ppGroupVisibleForTest("pp.off")
                  && !sw.ppGroupVisibleForTest("pp.summary") && !sw.ppGroupVisibleForTest("pp.shell"))
            // Transcription hints: parsing (comma/newline/#comment), case-insensitive dedupe, cap.
            check("hints: parse comma/newline + comments",
                  parseHintTerms("Kubernetes, gRPC\n# note\n김철수\n\n") == ["Kubernetes", "gRPC", "김철수"])
            check("hints: comment runs to end of line (commas inside don't leak) + inline comment",
                  parseHintTerms("# old, stuff\nAlpha # trailing, note\nBeta") == ["Alpha", "Beta"])
            // Transcript-level echo suppression — cases lifted from the user's real screenshot.
            check("echo text: exact copy suppressed",
                  isLikelyEcho(mine: "Over time, I got better at finding it.",
                               theirs: "Over time, I got better at finding it."))
            check("echo text: garbled copy suppressed",   // a garbled mic copy shares ≥80% of its tokens
                  isLikelyEcho(mine: "I wasn't very very find the award in the beginning, but I",
                               theirs: "I wasn't very good at finding north in the beginning, but I additioned a fair amount, and so my dad kept asking me, which way is north?"))
            check("echo text: unrelated line kept",
                  !isLikelyEcho(mine: "That's like a one of my life.",
                                theirs: "Not just by how far my life has come since then, but..."))
            check("echo text: short reply never eaten",
                  !isLikelyEcho(mine: "Yes.", theirs: "Yes.") && !isLikelyEcho(mine: "네 네 네", theirs: "네 네 네 알겠습니다"))
            let echoMerged: [(start: Double, who: String, text: String)] = [
                (10, "상대", "Over time, I got better at finding it."),
                (12, "나", "Over time, I got better at finding it."),     // echo → dropped
                (14, "나", "완전히 다른 내 얘기를 길게 하고 있어요"),         // genuine → kept
                (40, "나", "Over time, I got better at finding it."),     // outside ±8 s → kept
            ]
            let echoOut = suppressEchoLines(echoMerged, mine: "나")
            check("echo text: merged transcript drops only the in-window copy",
                  echoOut.map { $0.start } == [10, 14, 40])
            // Recording schedule: day parsing (ranges incl. wrap), hour ranges (lunch gap), isActive.
            check("schedule: day parsing",
                  RecordSchedule.parseDays("mon-fri") == [2, 3, 4, 5, 6]
                  && RecordSchedule.parseDays("MON, wed,fri") == [2, 4, 6]
                  && RecordSchedule.parseDays("sat-mon") == [7, 1, 2]      // wraps the week
                  && RecordSchedule.parseDays("nope, mon") == [2]          // junk skipped
                  && RecordSchedule.parseDays("") == [])
            check("schedule: hour-range parsing",
                  RecordSchedule.parseRanges("10:00-12:00, 13:00-19:00").map { [$0.start, $0.end] } == [[600, 720], [780, 1140]]
                  && RecordSchedule.parseRanges("23:00-24:00").map { [$0.start, $0.end] } == [[1380, 1440]]
                  && RecordSchedule.parseRanges("garbage, 25:00-26:00, 10:00-10:00").isEmpty)   // invalid/empty skipped
            check("schedule: pasted dashes + overnight wrap",
                  RecordSchedule.parseRanges("10:00–12:00").map { [$0.start, $0.end] } == [[600, 720]]      // en dash
                  && RecordSchedule.parseRanges("13:00~19:00").map { [$0.start, $0.end] } == [[780, 1140]]  // tilde range
                  && RecordSchedule.parseDays("mon–fri") == [2, 3, 4, 5, 6]
                  && RecordSchedule.parseRanges("22:00-06:00").map { [$0.start, $0.end] } == [[1320, 1440], [0, 360]])
            check("schedule: invalid input detected (never silently records 24/7)",
                  !RecordSchedule.hoursValid("10am-7pm") && !RecordSchedule.hoursValid("10:00-10:00")
                  && RecordSchedule.hoursValid("10:00–12:00, 13:00~19:00") && RecordSchedule.hoursValid("")
                  && !RecordSchedule.daysValid("mon-frii") && RecordSchedule.daysValid("mon–fri") && RecordSchedule.daysValid(""))
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
            func schedDate(_ s: String) -> Date {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = utc.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"; return f.date(from: s)!
            }
            let sched = RecordSchedule.from(enabled: true, days: "mon-fri", hours: "10:00-12:00, 13:00-19:00")
            check("schedule: mon-fri work hours minus lunch",
                  sched.isActive(at: schedDate("2026-07-06 10:00"), calendar: utc)      // Mon 10:00 → on
                  && !sched.isActive(at: schedDate("2026-07-06 12:30"), calendar: utc)  // lunch gap → off
                  && sched.isActive(at: schedDate("2026-07-06 18:59"), calendar: utc)
                  && !sched.isActive(at: schedDate("2026-07-06 19:00"), calendar: utc)  // end is exclusive
                  && !sched.isActive(at: schedDate("2026-07-05 11:00"), calendar: utc)) // Sunday → off
            check("schedule: disabled = always on; half-filled form never stops recording",
                  RecordSchedule.from(enabled: false, days: "", hours: "").isActive(at: schedDate("2026-07-05 03:00"), calendar: utc)
                  && RecordSchedule.from(enabled: true, days: "mon-fri", hours: "").isActive(at: schedDate("2026-07-06 03:00"), calendar: utc)
                  && RecordSchedule.from(enabled: true, days: "", hours: "10:00-11:00").isActive(at: schedDate("2026-07-05 10:30"), calendar: utc))
            // Menu hover: a view-backed item gets NO native highlight — MenuHoverView must provide
            // the selection pill + notify the label restyle, and reset when the menu reopens.
            do {
                let hv = MenuHoverView(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
                var hoverStates: [Bool] = []
                hv.onHover = { hoverStates.append($0) }
                let initiallyOff = !hv.highlightVisibleForTest
                hv.setHover(true)
                let litAndNotified = hv.highlightVisibleForTest && hoverStates == [true]
                hv.setHover(false)
                let offAgain = !hv.highlightVisibleForTest && hoverStates == [true, false]
                check("menu hover: pill shows on hover, hides after, restyle notified",
                      initiallyOff && litAndNotified && offAgain)
                check("menu hover: tracking area installed (mouse enter/exit will arrive)",
                      hv.trackingReadyForTest)
            }
            // Transcribe-now push: terminal statuses notify (the menu may be closed by then),
            // transient ones keep waiting — a dangling flag would mis-attribute the NEXT hourly segment.
            // Post-processing was invisible: it ran, left nothing behind, and the app read as broken.
            let stamp = schedDate("2026-07-07 12:03")
            let hm: (Date) -> String = { d in let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
                                             f.timeZone = utc.timeZone; f.dateFormat = "HH:mm"; return f.string(from: d) }
            check("tray: the summary row names the state, the file and when it happened",
                  summaryMenuTitle(.off, hm: hm) == "Summaries: off"
                  && summaryMenuTitle(.idle, hm: hm) == "Summary: after the next transcript"
                  && summaryMenuTitle(.running("a.md"), hm: hm) == "Summary: running… a.md"
                  && summaryMenuTitle(.done("a.md", stamp), hm: hm) == "Summary: a.md · 12:03"
                  && summaryMenuTitle(.failed("a.md", stamp, reason: "Not logged in"), hm: hm)
                     == "Summary FAILED: a.md · 12:03")
            // A row that is clickable must DO something. Enablement and the click read one decision, so
            // they cannot disagree — clicking a failure explains it, never nothing.
            // A freeform shell hook writes nowhere we know: nothing to reveal, no partial to reap.
            check("summary: only the built-in summary mode writes a file we can reveal or reap",
                  postProcessWritesSummaryFile(.summary)
                  && !postProcessWritesSummaryFile(.shell)
                  && !postProcessWritesSummaryFile(.off)
                  && summaryRowAction(.done("a.md", stamp), lastOutput: nil) == .none)   // shell mode
            check("tray: the summary row's click always has an outcome, and a failure explains itself",
                  summaryRowAction(.failed("a.md", stamp, reason: "Not logged in · Please run /login"), lastOutput: nil)
                  == .explain("a.md", "Not logged in · Please run /login")
                  && summaryRowAction(.failed("a.md", stamp, reason: nil), lastOutput: "/s/old.md")
                  == .explain("a.md", nil)                        // failure wins over a stale old file
                  && summaryRowAction(.done("a.md", stamp), lastOutput: "/s/a.md") == .reveal("/s/a.md")
                  && summaryRowAction(.idle, lastOutput: nil) == .none
                  && summaryRowAction(.off, lastOutput: "/s/a.md") == .none)
            // The runner writes STDOUT to `<out>.partial` and only then promotes it, so its error message
            // lands INSIDE that file, never on stderr. `claude` exiting 1 with "Not logged in" left only
            // "exit 1" in the log, and the orphaned .partial piled up in the notes vault for days.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("macrec-reap-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let outPath = tmp.appendingPathComponent("2026-07-10-1030-standup.md").path
            try? "Not logged in · Please run /login\n".write(toFile: outPath + ".partial", atomically: true, encoding: .utf8)
            let reason = reapFailedPostProcess(outPath: outPath)
            let orphanGone = !FileManager.default.fileExists(atPath: outPath + ".partial")
            let noReason = reapFailedPostProcess(outPath: tmp.appendingPathComponent("absent.md").path)
            // Blank leading lines must not be mistaken for "no reason"; a runner that streamed megabytes
            // before dying must not be slurped whole; invalid UTF-8 must not throw the reason away.
            let blankPath = tmp.appendingPathComponent("blank.md").path
            try? "\n\n   \nreal reason here\n".write(toFile: blankPath + ".partial", atomically: true, encoding: .utf8)
            let skipsBlanks = reapFailedPostProcess(outPath: blankPath) == "real reason here"
            let emptyPath = tmp.appendingPathComponent("empty.md").path
            try? "".write(toFile: emptyPath + ".partial", atomically: true, encoding: .utf8)
            let emptyIsNil = reapFailedPostProcess(outPath: emptyPath) == nil
            let emptyGone = !FileManager.default.fileExists(atPath: emptyPath + ".partial")
            let hugePath = tmp.appendingPathComponent("huge.md").path
            try? ("error first\n" + String(repeating: "x", count: 5_000_000))
                .write(toFile: hugePath + ".partial", atomically: true, encoding: .utf8)
            let hugeOK = reapFailedPostProcess(outPath: hugePath) == "error first"
            let badPath = tmp.appendingPathComponent("bad.md").path
            try? Data([0xFF, 0xFE, 0x0A] + Array("boom".utf8)).write(to: URL(fileURLWithPath: badPath + ".partial"))
            let badOK = reapFailedPostProcess(outPath: badPath) != nil   // lossy decode, not a crash or nil
            try? FileManager.default.removeItem(at: tmp)
            check("summary: a failed runner's reason is read back from its .partial, which is then removed",
                  reason == "Not logged in · Please run /login" && orphanGone && noReason == nil
                  && skipsBlanks && emptyIsNil && emptyGone && hugeOK && badOK)
            // The marker used to be stamped BEFORE the run. A login error at 20:00 then marked the day
            // done, and the digest never retried — exactly what happened on 2026-07-09 and 07-10.
            check("digest: only a run that wrote a file (or can never succeed today) retires the day",
                  digestMarksDayDone(.wrote)
                  && digestMarksDayDone(.nothingToDo)      // no meetings — retrying finds none either
                  && digestMarksDayDone(.wouldOverwrite)   // the name collides until the user changes it
                  && !digestMarksDayDone(.runnerFailed))   // no login / no network — retry on the next tick
            check("tray: the digest row says off, due, or already written today",
                  digestMenuTitle(enabled: false, dueTime: "20:00", lastRun: "", today: "2026-07-07")
                  == "Daily digest: off"
                  && digestMenuTitle(enabled: true, dueTime: "20:00", lastRun: "", today: "2026-07-07")
                  == "Daily digest: due at 20:00"
                  && digestMenuTitle(enabled: true, dueTime: "20:00", lastRun: "2026-07-07", today: "2026-07-07")
                  == "Daily digest: written today"
                  && digestMenuTitle(enabled: true, dueTime: "20:00", lastRun: "2026-07-06", today: "2026-07-07")
                  == "Daily digest: due at 20:00")
            // A summary that ran must be reachable: the row is only clickable once it produced a file.
            SummaryStatus.shared.resetForTest()
            let noOutput = SummaryStatus.shared.lastOutput == nil && SummaryStatus.shared.current == .idle
            SummaryStatus.shared.started("a.md")
            let running = SummaryStatus.shared.current == .running("a.md")
            SummaryStatus.shared.finished("a.md", at: stamp, output: "/s/a.md")
            check("tray: summary status tracks running → done and remembers the file it wrote",
                  noOutput && running
                  && SummaryStatus.shared.current == .done("a.md", stamp)
                  && SummaryStatus.shared.lastOutput == "/s/a.md")
            // The row reads BOTH halves under one lock. Reading them separately let a failure land between
            // the two, so the row offered to reveal a file for the run that had just failed.
            SummaryStatus.shared.failed("b.md", at: stamp, reason: "boom")
            let (act, out) = SummaryStatus.shared.snapshot
            check("tray: a failure carries its reason all the way to the row's click",
                  summaryRowAction(act, lastOutput: out) == .explain("b.md", "boom")
                  && out == "/s/a.md"                       // a stale success path is still remembered…
                  && summaryRowAction(act, lastOutput: out) != .reveal("/s/a.md"))   // …but never offered
            SummaryStatus.shared.resetForTest()
            // The row is a control, and a control wired to nothing looks perfect until you click it.
            check("tray: the summary row's reveal action is implemented",
                  AppController.instancesRespond(to: Selector(("revealLastSummary"))))
            // …and menuWillOpen must actually REFRESH those rows. Drive the real menu: a deleted
            // refreshPostProcessRows() call would leave both titles empty, and this check red.
            // Pin the mode: with no saved pref (a fresh machine, and CI) the effective mode is .off and the
            // row reads "Summaries: off", which says nothing about whether menuWillOpen refreshed it.
            let savedMode = Pref.d.object(forKey: Pref.postProcessMode)
            Pref.d.set(PostProcessMode.summary.rawValue, forKey: Pref.postProcessMode)
            SummaryStatus.shared.resetForTest()
            SummaryStatus.shared.failed("z.md", at: stamp, reason: "runner exploded")
            let rows = AppController().postProcessRowsAfterMenuOpenForTest()
            check("tray: opening the menu refreshes the post-process rows from live status",
                  rows != nil
                  && rows!.summary.contains("z.md")               // the live failure, not the built-in empty title
                  && rows!.digest.hasPrefix("Daily digest"))
            if let savedMode { Pref.d.set(savedMode, forKey: Pref.postProcessMode) }
            else { Pref.d.removeObject(forKey: Pref.postProcessMode) }
            // A row with nothing to show must be GREY after AppKit's validation pass, not merely after
            // our own `isEnabled = false`. The menu auto-enables items, so validateMenuItem has the last
            // word — assigning isEnabled and reading it straight back was a test asserting itself.
            SummaryStatus.shared.resetForTest()   // .idle, no output → the row can do nothing
            let idleRows = AppController().postProcessRowsAfterMenuOpenForTest()
            check("tray: a summary row with nothing to reveal is disabled after AppKit re-validates it",
                  idleRows != nil && idleRows!.enabled == false)
            check("flush push: terminal statuses classified, transient ones wait",
                  flushOutcome(for: "Saved: 2026-07-05-2100-2130.md")! == ("Transcript ready", "2026-07-05-2100-2130.md")
                  && flushOutcome(for: "No speech — discarded") != nil
                  && flushOutcome(for: "No speech — skipped") != nil
                  && flushOutcome(for: "Downloading model — transcription deferred") != nil
                  && flushOutcome(for: "Transcription failed") != nil
                  // Every status `process` can END on must classify, or "Transcribe now" hangs on its
                  // spinner and the still-armed flag steals the next segment's notification.
                  && flushOutcome(for: "No meeting · short — skipped") != nil
                  && flushOutcome(for: "Transcribing…") == nil
                  && flushOutcome(for: "Recording · mic + system audio") == nil
                  && flushOutcome(for: "Paused (locked/asleep)") == nil)
            check("flush push: spinner holds to a visible minimum, never negative",
                  abs(spinnerHold(elapsed: 0.3) - 0.7) < 1e-9
                  && spinnerHold(elapsed: 1.0) == 0
                  && spinnerHold(elapsed: 45) == 0
                  && spinnerHold(elapsed: 0) == 1.0)
            // L3 daily digest: due-logic (deadline + once-a-day marker = sleep catch-up), input
            // preference (summary over transcript, matched by basename), path fallbacks, invocation.
            check("digest: due after deadline, once per day, junk time never fires",
                  dailyDigestDue(now: schedDate("2026-07-07 20:01"), time: "20:00", lastRun: "", calendar: utc)
                  && !dailyDigestDue(now: schedDate("2026-07-07 19:59"), time: "20:00", lastRun: "", calendar: utc)
                  && !dailyDigestDue(now: schedDate("2026-07-07 20:01"), time: "20:00", lastRun: "2026-07-07", calendar: utc)
                  && dailyDigestDue(now: schedDate("2026-07-08 23:00"), time: "20:00", lastRun: "2026-07-07", calendar: utc)
                  && !dailyDigestDue(now: schedDate("2026-07-07 20:01"), time: "25:99", lastRun: "", calendar: utc))
            check("digest: inputs prefer the summary, fall back to the transcript, day-filtered + sorted",
                  dailyDigestInputs(day: "2026-07-07",
                                    transcripts: ["/t/2026-07-07-1400.md", "/t/2026-07-06-1000.md", "/t/2026-07-07-1000-standup.md"],
                                    summaries: ["/s/2026-07-07-1000-standup.md"])
                  == ["/s/2026-07-07-1000-standup.md", "/t/2026-07-07-1400.md"])
            // A digest lands in the SAME month folder as the day's notes, and `2026-07-07.md` carries the
            // very day-prefix the input filter matches — without the exclusion it would feed itself its
            // own previous output. Compared by standardized path (`/t/./x.md` is the same file as `/t/x.md`).
            check("digest: the digest we're about to write is never one of its own inputs",
                  dailyDigestInputs(day: "2026-07-07",
                                    transcripts: ["/t/2026-07/./2026-07-07.md", "/t/2026-07/2026-07-07-1000-standup.md"],
                                    summaries: ["/t/2026-07/2026-07-07.md"],
                                    excluding: "/t/2026-07/2026-07-07.md")
                  == ["/t/2026-07/2026-07-07-1000-standup.md"])
            // The name is the user's to choose: default is a bare date, tokens expand, a missing
            // extension is added, and a blank or `/`-bearing template can't produce a nameless file
            // or escape the month folder.
            check("digest: file name comes from a user template, defaults to {date}.md",
                  dailyDigestFileName(day: "2026-07-07") == "2026-07-07.md"
                  && dailyDigestFileName(day: "2026-07-07", template: "") == "2026-07-07.md"
                  && dailyDigestFileName(day: "2026-07-07", template: "{date}-daily") == "2026-07-07-daily.md"
                  && dailyDigestFileName(day: "2026-07-07", template: ".md") == "2026-07-07.md"
                  && dailyDigestFileName(day: "2026-07-07", template: "../{date}.md") == "..-2026-07-07.md")
            // A template with no {date} resolved to one path for the whole month, and the digest is
            // promoted with `mv` — every day silently overwrote the day before.
            check("digest: a name without {date} still gets the day, so days can't overwrite each other",
                  dailyDigestFileName(day: "2026-07-07", template: "notes.md") == "2026-07-07-notes.md"
                  && dailyDigestFileName(day: "2026-07-07", template: "digest-{month}.md") == "2026-07-07-digest-2026-07.md")
            // A summary saved next to its transcript is `<base>-sum.md`; keying on the raw basename meant
            // the digest never found it and quietly fed on the raw transcript instead.
            check("digest: a `-sum` summary next to its transcript is matched to that transcript",
                  dailyDigestInputs(day: "2026-07-07",
                                    transcripts: ["/t/2026-07-07-1000-standup.md"],
                                    summaries: ["/t/2026-07-07-1000-standup-sum.md"])
                  == ["/t/2026-07-07-1000-standup-sum.md"])
            // No `Daily/` tree any more — we only ever create the month folder under the dir the user
            // picked; choosing where that folder lives is the user's job, not ours.
            check("digest: output path — <picked dir>/YYYY-MM/<name>, no injected Daily folder",
                  dailyDigestOutputPath(day: "2026-07-07", outDir: "/d", summaryOutDir: "/r/Summaries", transcriptsDir: "/r/Transcripts")
                  == "/d/2026-07/2026-07-07.md"
                  && dailyDigestOutputPath(day: "2026-07-07", outDir: "", summaryOutDir: "/r/Summaries", transcriptsDir: "/r/Transcripts")
                  == "/r/Summaries/2026-07/2026-07-07.md"
                  && dailyDigestOutputPath(day: "2026-07-07", outDir: "", summaryOutDir: "", transcriptsDir: "/r/Transcripts")
                  == "/r/Transcripts/2026-07/2026-07-07.md"
                  && dailyDigestOutputPath(day: "2026-07-07", outDir: "/d", summaryOutDir: "", transcriptsDir: "/r/T",
                                           nameTemplate: "{date}-daily.md") == "/d/2026-07/2026-07-07-daily.md")
            check("digest: invocation cats inputs into the runner with atomic promote",
                  dailyDigestInvocation(runner: .claude, prompt: "P", inputs: ["/s/a.md", "/s/b's.md"], outPath: "/d/2026-07/x.md")
                  == "mkdir -p '/d/2026-07' && cat '/s/a.md' '/s/b'\\''s.md' | claude -p 'P' "
                   + "> '/d/2026-07/x.md.partial' && mv '/d/2026-07/x.md.partial' '/d/2026-07/x.md'"
                  && dailyDigestInvocation(runner: .claude, prompt: "P", inputs: [], outPath: "/d/x.md") == nil)
            // Tail-scheduler decision — both timing regressions ("not real-time" = timer wait,
            // "second line slow" = firing while another request was in flight) lived here.
            check("live: tail fire decision (one in flight, only when moved, never after final)",
                  shouldFireTailTranslation(tail: "새 꼬리", lastSent: "", inFlight: false, final: false)
                  && !shouldFireTailTranslation(tail: "같음", lastSent: "같음", inFlight: false, final: false)
                  && !shouldFireTailTranslation(tail: "새 꼬리", lastSent: "옛", inFlight: true, final: false)
                  && !shouldFireTailTranslation(tail: "새 꼬리", lastSent: "", inFlight: false, final: true)
                  && !shouldFireTailTranslation(tail: "", lastSent: "옛", inFlight: false, final: false))
            // Rendering must stay IN ORDER while sentence translations land async: part 2 landing
            // before part 1 must NOT display until part 1 arrives; the volatile tail renders last.
            if #available(macOS 26, *) {
                var cl = LiveCaptions.CapLine(speaker: "나", text: "a. b. c", final: false, time: Date())
                cl.transParts = [nil, "TWO"]
                cl.transTail = "tail"
                let outOfOrderHidden = cl.translated == "tail"        // part 2 waits for part 1
                cl.transParts = ["ONE", "TWO"]
                let ordered = cl.translated == "ONE TWO tail"
                cl.transTail = nil
                let frozen = cl.translated == "ONE TWO"
                check("live: translation renders in order (late part 1 gates part 2; tail last)",
                      outOfOrderHidden && ordered && frozen)
            }
            // Live translation streams per COMPLETED sentence — the splitter must not fire on
            // decimals or on a trailing period that hasn't been confirmed by a following space.
            check("live: sentence splitter (decimals safe, tail waits, hard punct immediate)",
                  completeSentences("안녕하세요. 오늘 회의는") == ["안녕하세요."]
                  && completeSentences("3.5 퍼센트입니다. 다음 안건은") == ["3.5 퍼센트입니다."]
                  && completeSentences("됐나요? 정말요! 네.") == ["됐나요?", "정말요!"]
                  && completeSentences("아직 문장이 안 끝났") == []
                  && completeSentences("First point. Second point here") == ["First point."])
            // Update check: dotted-numeric compare (string compare says "0.10" < "0.9").
            check("update: version compare handles multi-digit, v-prefix, unequal lengths",
                  isNewerVersion("v0.6.0", than: "0.5.0")
                  && isNewerVersion("0.10.0", than: "0.9.9")
                  && isNewerVersion("1.0", than: "0.99.99")
                  && !isNewerVersion("v0.5.0", than: "0.5.0")
                  && !isNewerVersion("0.5", than: "0.5.0")
                  && !isNewerVersion("0.4.9", than: "0.5.0"))
            // File naming: start time only (the end time lived in the name briefly — clutter).
            check("naming: transcript base is the start time only",
                  transcriptBaseName(start: schedDate("2026-07-05 21:00"), timeZone: utc.timeZone) == "2026-07-05-2100"
                  && transcriptBaseName(start: schedDate("2026-07-05 23:50"), timeZone: utc.timeZone) == "2026-07-05-2350")
            // A mapped meeting stamps the transcript with the MEETING's start, clamped to the recorded
            // window: a 21:10 meeting inside the 21:00 rotation slice files as 21:10, while the second
            // hour of a 20:30 meeting still files as 21:00 — otherwise both slices of one long meeting
            // would claim 20:30, collapse onto the same name, and the later one would overwrite the first.
            let segA = schedDate("2026-07-05 21:00"), segAEnd = schedDate("2026-07-05 22:00")
            check("naming: a mapped calendar event stamps its own start, clamped to the recorded window",
                  transcriptStart(segStart: segA, segEnd: segAEnd, eventStart: nil) == segA
                  && transcriptStart(segStart: segA, segEnd: segAEnd,
                                     eventStart: schedDate("2026-07-05 21:10")) == schedDate("2026-07-05 21:10")
                  && transcriptStart(segStart: segA, segEnd: segAEnd,
                                     eventStart: schedDate("2026-07-05 20:30")) == segA          // continuation slice
                  && transcriptStart(segStart: segA, segEnd: segAEnd,
                                     eventStart: schedDate("2026-07-05 22:30")) == segAEnd       // matched on the +60s window
                  && transcriptBaseName(start: transcriptStart(segStart: segA, segEnd: segAEnd,
                                                               eventStart: schedDate("2026-07-05 21:10")),
                                        timeZone: utc.timeZone) == "2026-07-05-2110")
            // Naming an hour of audio after a calendar event: the 2026-07-08 15:00–16:02 segment was
            // titled after an event it shared 2 minutes with, because that event carried a Zoom
            // URL, while the kickoff that filled 60 of its 62 minutes had none. A link means "online",
            // not "this is the meeting you recorded"; it may only break a tie.
            let seg = schedDate("2026-07-08 15:00"), segEnd = schedDate("2026-07-08 16:02")
            let kickoff = EventCandidate(title: "project kickoff",         // 60 min of the segment
                                         start: schedDate("2026-07-08 14:00"),
                                         end: schedDate("2026-07-08 16:00"), hasLink: false)
            let goalCheck = EventCandidate(title: "goal progress check",     // 2 min
                                           start: schedDate("2026-07-08 16:00"),
                                           end: schedDate("2026-07-08 17:00"), hasLink: true)
            let nextDay = EventCandidate(title: "caught only by the ±padding",  // zero true overlap
                                         start: schedDate("2026-07-08 16:02"),
                                         end: schedDate("2026-07-08 17:00"), hasLink: true)
            func pick(_ cs: [EventCandidate]) -> String? {
                bestEventIndex(segStart: seg, segEnd: segEnd, candidates: cs).map { cs[$0].title }
            }
            // Same-overlap tie: the online meeting wins. Both cover 15:00–16:00 exactly.
            let inPerson = EventCandidate(title: "in person", start: seg,
                                          end: schedDate("2026-07-08 16:00"), hasLink: false)
            let online = EventCandidate(title: "online", start: seg,
                                        end: schedDate("2026-07-08 16:00"), hasLink: true)
            check("calendar: the event that FILLS the segment wins; a meeting link only breaks a tie",
                  pick([goalCheck, kickoff]) == "project kickoff"              // link no longer outranks
                  && pick([kickoff, goalCheck]) == "project kickoff"           // and order can't flip it
                  && pick([nextDay]) == nil                                    // zero overlap → no match
                  && pick([kickoff, nextDay]) == "project kickoff"
                  && pick([inPerson, online]) == "online"                      // tie → the online one
                  && pick([online, inPerson]) == "online"
                  && pick([]) == nil
                  && eventOverlap(kickoff, segStart: seg, segEnd: segEnd) == 3600
                  && eventOverlap(goalCheck, segStart: seg, segEnd: segEnd) == 120)
            // Dead-mic detection — the jack-input incident: hours of segments "voiced" by clicks
            // (energy-gate trips) while containing zero speech-length runs, all discarded silently.
            check("mic guard: speech-run accounting (clicks never qualify, speech does)",
                  speechlikeFrames(Array(repeating: 0.5, count: 799) + [0.0]) == 0        // 49.9 ms — just under
                  && speechlikeFrames(Array(repeating: 0.5, count: 800)) == 800           // 50 ms run qualifies fully
                  && speechlikeFrames(Array(repeating: 0.5, count: 1200)) == 1200
                  && speechlikeFrames((0..<8000).map { $0 % 100 < 8 ? 0.5 : 0.0 }) == 0   // click train
                  && speechlikeFrames(Array(repeating: 0.5, count: 900) + Array(repeating: 0.0, count: 100)
                                      + Array(repeating: 0.5, count: 900)) == 1800)       // two syllables
            check("mic guard: dead-input verdict (energy without speech runs)",
                  micLooksDead(voiced: 44.1, speech: 0.1)      // the real incident segment
                  && !micLooksDead(voiced: 22.4, speech: 8.0)  // real speech
                  && !micLooksDead(voiced: 3.0, speech: 0.0)   // quiet hour — no verdict
                  && !micLooksDead(voiced: 6.0, speech: 0.6))  // borderline but speech present
            // Hallucination scrubbing — the exact failure classes from our junk transcripts:
            // a broadcast hour where one sentence repeated for 15 minutes, YouTube-outro
            // boilerplate on quiet rooms, "oh oh oh…" degeneration. Real speech must survive.
            check("scrub: boilerplate + within-line loop dropped, real speech kept",
                  Transcriber.isHallucinatedLine("ご視聴ありがとうございました")
                  && Transcriber.isHallucinatedLine("시청해 주셔서 감사합니다.")
                  && Transcriber.isHallucinatedLine("Thanks for watching!")
                  && Transcriber.isHallucinatedLine(Array(repeating: "oh,", count: 28).joined(separator: " "))
                  && !Transcriber.isHallucinatedLine("이번 스프린트에 배포 파이프라인 마이그레이션을 마무리하기로 했습니다.")
                  && !Transcriber.isHallucinatedLine("네, 네. 알겠습니다.")
                  && !Transcriber.isHallucinatedLine("Let's start with the deployment status update."))
            // Review-verified false-positive victims that MUST survive: short real repetition
            // (backchannels, chants) under the 80-byte gate; sentences that merely MENTION
            // boilerplate phrases (anchored match, not contains).
            check("scrub: real Korean repetition + boilerplate mentions survive",
                  !Transcriber.isHallucinatedLine("네, 네, 네, 네, 네, 네, 네, 네, 네.")
                  && !Transcriber.isHallucinatedLine("파이팅 파이팅 파이팅 파이팅 파이팅")
                  && !Transcriber.isHallucinatedLine("Thank you for watching the demo, any questions before we move on?")
                  && !Transcriber.isHallucinatedLine("구독과 좋아요 버튼 위치를 바꾸는 A/B 테스트를 해 보죠."))
            check("scrub: dominant 4-gram loop detected, varied prose passes",
                  Transcriber.maxNgramShare(Array(repeating: "you should be able to get the ball", count: 8).joined(separator: " ")) > 0.1
                  && Transcriber.maxNgramShare("the quick brown fox jumps over the lazy dog while the calm river flows past the quiet village near the tall mountain") <= 0.06)
            do {
                // The observed 15-minute loop: one sentence every ~3 s for 240 lines. Collapses to
                // its first occurrence; identical REAL repeats far apart (>30 s) are both kept.
                let loop = (0..<240).map { (10.0 + Double($0) * 3, "You should be able to get the ball from the right side.") }
                let lines = [(5.0, "회의 시작하겠습니다.")] + loop + [(950.0, "다음 주제로 넘어가죠.")]
                let (kept, dropped) = Transcriber.scrubLines(lines)
                check("scrub: 240-line repetition loop collapses to one, neighbors survive",
                      kept.map { $0.1 } == ["회의 시작하겠습니다.",
                                            "You should be able to get the ball from the right side.",
                                            "다음 주제로 넘어가죠."] && dropped == 239)
                let farApart = [(10.0, "네."), (500.0, "네.")]
                check("scrub: identical backchannels far apart both survive",
                      Transcriber.scrubLines(farApart).kept.count == 2)
            }
            check("scrub: compression ratio separates loops from prose",
                  Transcriber.compressionRatio(String(repeating: "구독과 좋아요 부탁드립니다 ", count: 12)) > 2.4
                  && Transcriber.compressionRatio("오늘 논의된 내용은 세 가지였고 각각 담당자가 다음 주까지 정리하기로 했습니다.") < 2.4)
            // Audio archive tiers: raw → compressed → deleted, with 0 disabling a stage.
            check("audio tiers: raw → compressed → deleted (0 = never/forever)",
                  AudioArchivePolicy(rawDays: 7, totalDays: 90).tier(ageDays: 3) == .raw
                  && AudioArchivePolicy(rawDays: 7, totalDays: 90).tier(ageDays: 7) == .compressed
                  && AudioArchivePolicy(rawDays: 7, totalDays: 90).tier(ageDays: 90) == .deleted
                  && AudioArchivePolicy(rawDays: 0, totalDays: 90).tier(ageDays: 60) == .raw          // never compress
                  && AudioArchivePolicy(rawDays: 7, totalDays: 0).tier(ageDays: 400) == .compressed   // keep forever
                  && AudioArchivePolicy(rawDays: 30, totalDays: 14).tier(ageDays: 20) == .deleted)    // delete wins
            check("audio tiers: retention combo text parsing",
                  AudioArchivePolicy.parseRetentionDays("90 days") == 90
                  && AudioArchivePolicy.parseRetentionDays("1 year") == 365
                  && AudioArchivePolicy.parseRetentionDays("6 months") == 180
                  && AudioArchivePolicy.parseRetentionDays("2 weeks") == 14
                  && AudioArchivePolicy.parseRetentionDays("45") == 45
                  && AudioArchivePolicy.parseRetentionDays("Unlimited") == 0
                  && AudioArchivePolicy.parseRetentionDays("Don't compress") == 0
                  && AudioArchivePolicy.parseRetentionDays("soon") == nil
                  && AudioArchivePolicy.parseRetentionDays("") == nil
                  && AudioArchivePolicy.parseRetentionDays("9223372036854775807 years") == nil)  // typed live: red, not a trap
            check("audio tiers: titles round-trip through the parser",
                  [7, 90, 180, 365, 730, 0].allSatisfy {
                      AudioArchivePolicy.parseRetentionDays(AudioArchivePolicy.retentionTitle($0)) == $0
                  })
            // Real afconvert round-trip — would have caught 64 kbps being rejected ('!dat') at 16 kHz
            // mono. Also proves the retention clock survives archiving (mdate carried over).
            do {
                let fm = FileManager.default
                let dir = fm.temporaryDirectory.appendingPathComponent("macrec-selftest-\(ProcessInfo.processInfo.processIdentifier)")
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let wav = dir.appendingPathComponent("tone.wav"), m4a = dir.appendingPathComponent("tone.m4a")
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0,
                                               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]
                if let file = try? AVAudioFile(forWriting: wav, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false),
                   let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16000) {
                    buf.frameLength = 16000
                    for i in 0..<16000 { buf.floatChannelData![0][i] = sinf(Float(i) * 0.1) * 0.3 }
                    try? file.write(from: buf)
                }
                let past = Date(timeIntervalSinceNow: -86400 * 10)
                try? fm.setAttributes([.modificationDate: past], ofItemAtPath: wav.path)
                let ok = AudioArchiver.compress(wav, to: m4a)
                let size = (try? fm.attributesOfItem(atPath: m4a.path))?[.size] as? Int ?? 0
                let mdate = (try? m4a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                check("audio tiers: afconvert AAC round-trip keeps the retention clock",
                      ok && size > 0 && abs(mdate.timeIntervalSince(past)) < 2)
                try? fm.removeItem(at: dir)
            }
            // nextBoundary anchors the manual-override expiry: a wall-clock timestamp, so sleeping
            // across boundaries still expires it. Fri 20:00 → next flip is MONDAY 10:00 (skips the weekend).
            check("schedule: next boundary (lunch edge, weekend skip, never-flips → nil)",
                  sched.nextBoundary(after: schedDate("2026-07-06 11:00"), calendar: utc) == schedDate("2026-07-06 12:00")
                  && sched.nextBoundary(after: schedDate("2026-07-06 12:30"), calendar: utc) == schedDate("2026-07-06 13:00")
                  && sched.nextBoundary(after: schedDate("2026-07-10 20:00"), calendar: utc) == schedDate("2026-07-13 10:00")
                  && RecordSchedule.from(enabled: false, days: "mon-fri", hours: "").nextBoundary(after: schedDate("2026-07-06 11:00"), calendar: utc) == nil
                  && RecordSchedule.from(enabled: true, days: "", hours: "").nextBoundary(after: schedDate("2026-07-06 11:00"), calendar: utc) == nil)
            check("hints: dedupe (case-insensitive) + priority order",
                  mergeHintTerms(direct: ["Alpha", "Beta"], file: ["alpha", "Gamma"], event: ["Beta", "김철수"])
                  == ["Alpha", "Beta", "Gamma", "김철수"])
            check("hints: cap respected",
                  mergeHintTerms(direct: (1...100).map(String.init), file: [], event: []).count == 60)
            // Live pass-through: Deepgram gets per-term `keywords` boosts; OpenAI gets a transcription prompt.
            let dgURL = DeepgramLiveTranscriber.listenURL(lang: "ko", keywords: ["Kubernetes", "김철수"]).absoluteString
            check("hints: deepgram keywords in the listen URL",
                  dgURL.contains("keywords=Kubernetes") && dgURL.contains("keywords=") && dgURL.contains("language=ko"))
            let oaCfg = OpenAILiveTranscriber.sessionConfig(lang: "ko", hints: "Kubernetes, 김철수")
            let oaTr = (oaCfg["session"] as? [String: Any])?["input_audio_transcription"] as? [String: Any]
            let oaCfgNoHints = OpenAILiveTranscriber.sessionConfig(lang: "ko", hints: "")
            let oaTrNo = (oaCfgNoHints["session"] as? [String: Any])?["input_audio_transcription"] as? [String: Any]
            check("hints: openai transcription prompt set only when non-empty",
                  (oaTr?["prompt"] as? String) == "Kubernetes, 김철수" && oaTrNo?["prompt"] == nil)
            // Gladia engine: REST-init body (language + vocabulary only when present) + transcript parsing.
            let glBody = GladiaLiveTranscriber.initBody(lang: "ko", vocabulary: ["Kubernetes"])
            let glLangs = (glBody["language_config"] as? [String: Any])?["languages"] as? [String]
            let glVocab = (((glBody["realtime_processing"] as? [String: Any])?["custom_vocabulary_config"]
                            as? [String: Any])?["vocabulary"]) as? [String]
            let glPlain = GladiaLiveTranscriber.initBody(lang: "", vocabulary: [])
            check("gladia: init body carries language + vocabulary only when present",
                  glLangs == ["ko"] && glVocab == ["Kubernetes"]
                  && glPlain["language_config"] == nil && glPlain["realtime_processing"] == nil
                  && glPlain["sample_rate"] as? Int == 16000)
            var glGot: [(String, Bool)] = []
            let gl = GladiaLiveTranscriber(label: "t", locale: Locale(identifier: "ko-KR")) { s, f in glGot.append((s, f)) }
            gl.handle(#"{"type":"transcript","data":{"is_final":false,"utterance":{"text":" 안녕하세"}}}"#)
            gl.handle(#"{"type":"transcript","data":{"is_final":true,"utterance":{"text":"안녕하세요"}}}"#)
            gl.handle(#"{"type":"transcript","data":{"is_final":true,"utterance":{"text":"  "}}}"#)   // blank → dropped
            gl.handle(#"{"type":"audio_chunk","acknowledged":true}"#)                                  // ack → dropped
            gl.handle("junk")                                                                          // junk → dropped
            check("gladia: partial/final parsing (trimmed, junk dropped)", glGot.count == 2
                  && glGot[0] == ("안녕하세", false) && glGot[1] == ("안녕하세요", true))
            print(fails == 0 ? "selftest: ALL PASS" : "selftest: \(fails) FAILED")
            exit(fails == 0 ? 0 : 1)
}
