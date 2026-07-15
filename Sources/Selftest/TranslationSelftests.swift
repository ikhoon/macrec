import AppKit
import AVFoundation
import EventKit
import Foundation

func translationSelftests(_ check: (String, Bool) -> Void) {
    // Live translation provider: DeepL is honored only with a key, else demote to Apple — the same
    // "don't offer what can't run" rule the transcription engines follow. Pure decision.
    check("translate provider: DeepL needs a key, else Apple",
          translationProvider(stored: .deepl, deeplReady: true)  == .deepl
          && translationProvider(stored: .deepl, deeplReady: false) == .apple   // no key → fall back
          && translationProvider(stored: .apple, deeplReady: true)  == .apple)
    // Sentence-streamed translation renders the in-order prefix of landed parts. A nil part = a sentence
    // still IN FLIGHT → stop (keep order). But a sentence that FAILED both attempts must store its
    // original as a fallback (non-nil), or that one failure truncates every later sentence until finalize.
    check("translated prefix: a failed sentence's fallback avoids truncating later ones (DeepL bug)",
          translatedPrefix(["A", "B", "C"], tail: nil) == "A B C"
          && translatedPrefix(["A", nil, "C"], tail: nil) == "A"                  // nil = in flight → stop in order
          && translatedPrefix(["A", "b(orig)", "C"], tail: nil) == "A b(orig) C"  // FAILED → fallback → NO truncation
          && translatedPrefix(["A"], tail: "tail") == "A tail"
          && translatedPrefix([], tail: nil) == nil)
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
                             bodyMine: "나", bodyTheirs: "상대", body: "hello", eventNotes: nil)
    let mdKo = tDoc.markdown(.forLanguage("ko")), mdEn = tDoc.markdown(.forLanguage("en")), mdJa = tDoc.markdown(.forLanguage("ja"))
    check("transcript md: section localized",
          mdKo.contains("## 전사 (transcript)") && mdEn.contains("## Transcript") && mdJa.contains("## 文字起こし"))
    check("transcript md: labels localized",
          mdKo.contains("- 시각:") && mdEn.contains("- Time:") && mdJa.contains("- 時刻:") && mdEn.contains("(60 min)"))
    check("transcript md: note keeps BODY speaker labels",
          mdEn.contains("나 = microphone") && mdEn.contains("Excluded: com.spotify.client"))
    check("transcript md: workflow footer removed",
          !mdKo.contains("자동 생성") && !mdKo.contains("topics/") && !mdEn.contains("topics/"))
    // Calendar meeting notes ride the transcript (context for the reader AND the summarizer): a localized
    // section when the event has notes, and no stray heading when it doesn't.
    var tDocN = tDoc; tDocN.eventNotes = "agenda: ship v2"
    check("transcript md: calendar notes get a localized section, absent notes leave no heading",
          tDocN.markdown(.forLanguage("ko")).contains("## 미팅 노트 (calendar)\n\nagenda: ship v2")
          && tDocN.markdown(.forLanguage("en")).contains("## Meeting notes (calendar)\n\nagenda: ship v2")
          && !mdEn.contains("Meeting notes"))
    // The notes are trimmed, nil when empty, and capped so invite boilerplate can't drown the transcript.
    check("transcript md: calendar notes trimmed / empty→nil / capped",
          calendarNotesForTranscript("  agenda \n") == "agenda"
          && calendarNotesForTranscript("   \n ") == nil && calendarNotesForTranscript(nil) == nil
          && calendarNotesForTranscript(String(repeating: "a", count: 5000))!.count == 4001
          && calendarNotesForTranscript(String(repeating: "a", count: 5000))!.hasSuffix("…"))
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
    // The summary file's H1 equals its FILE name (user rule), composed only AFTER the runner succeeds —
    // a failed run's .partial keeps the runner's own words (the reap contract), never a header line.
    let sumCmd = inv(.summary, .claude) ?? ""
    check("post-process: claude summary template (mkdir + runner → .partial, H1 composed on success)",
          sumCmd.hasPrefix("mkdir -p '/t' && claude -p 'P' < '/t/a b'\\''s.md' > '/t/a b'\\''s-sum.md.partial'")
          && sumCmd.contains("&& { printf '# %s\\n\\n' 'a b'\\''s-sum'; cat '/t/a b'\\''s-sum.md.partial'; }")
          && sumCmd.contains("&& mv '/t/a b'\\''s-sum.md.partial2' '/t/a b'\\''s-sum.md'")
          && sumCmd.hasSuffix("&& rm -f '/t/a b'\\''s-sum.md.partial'"))
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
}
