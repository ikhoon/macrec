# macrec — backlog

Transparent, SCM-tracked todo list (GitHub Issues would be overkill; nothing sensitive here).
Grouped by the `VISION.md` pillars. Checked = done/merged. Kept current as work lands.

## Now — in progress
- [ ] **Modularize `Sources/` into per-module directories** — pure byte-identical moves, one module/PR.
      Audio/ ✅ (#99). Next: Live/, Pipeline/, Settings/, Tray/.
- [ ] **Reusable streaming base** (#52) — collapse the 5 WebSocket clients into one `StreamingWSTranscriber`
      + per-provider spec. Step 1 (shared PCM16 conversion) ✅ merged (#98). Next: the base + per-engine specs.

## Pillar 1 — ambient daily tracking → LLM-actionable knowledge
- [ ] Make the daily log **structured + machine-readable** (entities, decisions, action items), not prose.
- [ ] Expose the daily log to an agent/LLM (queryable store / MCP surface) so it can act on the day.
- [ ] Selectable calendar fields in the transcript header, fed to the summarizer (#31).
- [ ] Finish the Summaries tab (#4).

## Pillar 2 — real-time cross-language understanding
- [ ] **Interpretation compose path** (#50): mic → STT → translate → TTS(target) → **virtual audio device**.
      Foundation ✅ (stages + `SpeakingStage`, merged #95). Next: wire into the pipeline + Settings + routing.
- [ ] Cloud speech-to-speech stage: **OpenAI `gpt-realtime-translate`** (audio→JA audio, ~$0.034/min);
      Azure "Live Interpreter" preserves the speaker's voice. (Paid — needs the maintainer's go-ahead.)
- [ ] Reverse direction: what I hear → my language, spoken.
- [ ] Configurable caption + translation text colors (#34).
- [ ] Subtitle mode: position, line count, window chrome (#43).

## Quality (priority zero)
- [x] ElevenLabs Scribe STT — best ko/ja (#97, merged).
- [x] DeepL translation (#93, merged).
- [ ] Validate an API key with a real authenticated probe (#32).
- [ ] Debug visibility for cloud API traffic (#24) — partly done (DeepL error body logged).

## Infra / refactor
- [ ] Modularize `Selftest.swift` into per-module selftest files (#53) — after the code splits land.
- [ ] Add `///` doc comments to top-level types + key APIs, per module (#54) — separate from the pure moves.
- [ ] Evaluate/adopt a build tool — hybrid SwiftPM (compile+index+`swift test`), scripts keep the `.app` (#55).
- [ ] AEC taps: share one output-device snapshot across the filtered + reference tap (#44).
- [ ] Serialize `CaptureSession` mutating ops across its unstructured Tasks (#45).

## UX / polish
- [ ] Settings: warn before Close discards unsaved edits (#35).
- [ ] UI consistency pass across all Settings panes (#26).

## Bugs / edges
- [ ] DeepL: a sentence failing both retry attempts truncates the line's translation until finalize (#48).
