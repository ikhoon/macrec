# macrec — backlog

Transparent, SCM-tracked todo list (GitHub Issues would be overkill; nothing sensitive here).
Grouped by the `VISION.md` pillars. Checked = done/merged. Kept current as work lands.

## Now — in progress

- [ ] **Today dashboard follow-ups** (increment 1 shipped: capture/permissions/pipeline/output health
      with fix buttons, tray → Today… ⌘D). Next: a verdict for the *dropped-metric* silent-failure
      class (all-audio-scored-0s → everything discarded) — needs a live segment-level speech signal,
      not just the last-run status; a red→system-notification path so a closed window still warns;
      per-permission Settings deep-link.

- [x] **Modularize `Sources/` into per-module directories** — pure byte-identical moves, one module/PR.
      Audio/ · Live/ (#99), Tray/ (#106), Pipeline/ (#107), Settings/ (#108), Selftest/ (#109). All done.
- [ ] **Eval harness — ko/ja quality measurement** (quality priority zero). CER metrics (ja/ko) ✅ (#110).
      `macrec eval` runner ✅ — corpus dir + shell-template engines + CER/RTF report + hypothesis dump
      (first A/B: transcribe.cpp loads our ggml-large-v3.bin at 1.9× whisper-cli's speed with parity
      output; Qwen3-ASR promising, SenseVoice fast but weaker ko/ja). Next: ground-truth references,
      chrF + translation eval, cloud opt-in.
- [ ] **Reusable streaming base** (#52) — collapse the 5 WebSocket clients into one `StreamingWSTranscriber`
      + per-provider spec. Step 1 (shared PCM16 conversion) ✅ merged (#98). Next: the base + per-engine specs.

## Pillar 1 — ambient daily tracking → LLM-actionable knowledge

- [ ] Make the daily log **structured + machine-readable** (entities, decisions, action items), not prose.
      Increment 1 shipped: a validated JSON sidecar (`<date>.json`) written beside the digest after it
      lands (opt-outable Settings toggle, default on). Next: surface it in the Library / expose it as a
      queryable store or MCP surface (below).
- [ ] Expose the daily log to an agent/LLM (queryable store / MCP surface) so it can act on the day.
- [ ] Selectable calendar fields in the transcript header, fed to the summarizer (#31).
- [ ] Finish the Summaries tab (#4).
- [ ] **Live AI actions on the session** — summarize / extract action items in-place on the running
      transcript (reuse the summarizer), so a meeting becomes an LLM-actionable log without waiting for
      the batch pipeline. Our differentiator, surfaced live. *(MacWhisper live-UI comparison)*

## Pillar 2 — real-time cross-language understanding

- [ ] **Interpretation compose path** (#50): mic → STT → translate → TTS(target) → **virtual audio device**.
      Foundation ✅ (stages + `SpeakingStage`, merged #95). Next: wire into the pipeline + Settings + routing.
- [ ] Cloud speech-to-speech stage: **OpenAI `gpt-realtime-translate`** (audio→JA audio, ~$0.034/min);
      Azure "Live Interpreter" preserves the speaker's voice. (Paid — needs the maintainer's go-ahead.)
- [ ] Reverse direction: what I hear → my language, spoken.
- [ ] Configurable caption + translation text colors (#34).
- [ ] Subtitle mode: position, line count, window chrome (#43).
- [ ] **Readable live transcript view** — a resizable companion window (scroll + search) so a session
      doesn't evaporate when the overlay closes; the overlay stays glanceable. Feeds Pillar 1.
      *(MacWhisper's live view is a persistent, searchable, exportable document; ours is ephemeral.)*
- [ ] **Export the live transcript** — Markdown / SRT / VTT / txt, plus per-utterance copy (today: only
      whole-buffer copy).
- [ ] **Surface meeting context in the live overlay** — show the mapped calendar title in the header +
      auto start/stop on meeting detect (the pipeline titles transcripts; the live UI never shows it).
- [ ] **Overlay polish** — emphasize the current speaker/line, thin the control-bar density (progressive
      disclosure), tighten typography/spacing.

## Quality (priority zero)

- [x] ElevenLabs Scribe STT — best ko/ja (#97, merged).
- [x] DeepL translation (#93, merged).
- [ ] Validate an API key with a real authenticated probe (#32).
- [ ] Debug visibility for cloud API traffic (#24) — partly done (DeepL error body logged).
- [ ] **N-speaker diarization** within "them" — today speakers are the me/them 2-way (mic vs system
      audio); MacWhisper labels + names N speakers. Accuracy work, model-dependent. *(MacWhisper gap)*
      Evaluated 2026-07-19: MOSS-Transcribe-Diarize (transcribe.cpp, 46× RTF) is **en/zh only** —
      empty output on real ko clips, so it can't close the gap yet. The SHAPE is right (inline
      diarization in the ASR pass); revisit when a ko/ja-capable diarizing model lands. Our
      dual-channel truth (mic=me, sys=them) can score any candidate automatically.

## Infra / refactor

- [x] **SwiftFormat** formatter — allowlist hygiene config (`.swiftformat`) + pinned CI lint (#102).
- [ ] **SwiftLint** linter — needs full Xcode locally (its sourcekit won't load on a CommandLineTools-only
      machine — it crashes); add `.swiftlint.yml` + a CI step once Xcode is installed. SwiftFormat covers
      formatting meanwhile. Markdown is already linted in CI (markdownlint-cli2, #101).
- [ ] Modularize `Selftest.swift` into per-module selftest files (#53) — after the code splits land.
- [ ] Add `///` doc comments to top-level types + key APIs, per module (#54) — separate from the pure moves.
- [ ] Evaluate/adopt a build tool — hybrid SwiftPM (compile+index+`swift test`), scripts keep the `.app` (#55).
- [ ] AEC taps: share one output-device snapshot across the filtered + reference tap (#44).
- [ ] Serialize `CaptureSession` mutating ops across its unstructured Tasks (#45).

## UX / polish

- [ ] Settings: warn before Close discards unsaved edits (#35).
- [ ] UI consistency pass across all Settings panes (#26).
- [ ] **Inline transcript editing** — fix STT errors in place (improves the saved log). *(MacWhisper Editor)*
- [x] **Playback sync** — click a transcript line → jump to that point in the recorded audio (post-session
      review). *(MacWhisper)* Done in the Library preview (Increment 2), with transcript Export…
      (md/txt/SRT/VTT) and a Re-run summary header action.
- [ ] Library follow-ups from the Increment-2 review: a Library-run "Summarize" doesn't retitle an
      untitled transcript (the engine's automatic run does, via `extractTitleIfUntitled` — needs an
      engine handle in the window); failed summaries surface in the preview header but not yet as a
      trailing icon on the list row; failure memory is the in-memory `SummaryStatus` slot, so only the
      most recent engine failure survives (persistence would need a sidecar marker).

## Bugs / edges

- [ ] DeepL: a sentence failing both retry attempts truncates the line's translation until finalize (#48).
