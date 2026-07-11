# macrec — product vision (north star)

Recording is table stakes. macrec has **two core values**; everything else serves them.

## 1. Ambient daily tracking → LLM-actionable knowledge
Silently track the user's day and produce a **daily log** that an LLM re-absorbs to *perform work*.
The recording → transcript → summary → daily-digest chain is only the seed. The goal is a **structured,
queryable record of the day** — meetings, people, decisions, action items, context — that an agent can
read and act on (schedule, draft, remind, answer "what did we decide about X?"). The log is not a diary;
it is a knowledge substrate.

## 2. Real-time cross-language understanding
- Show any speaker's words as **live captions**.
- Speak **my** words out in another language (I say Korean → the listener hears Japanese).
- Render what **I hear** into **my** language.
Bidirectional, real-time, any-language.

## Where we are: ~1%. The blocker is QUALITY.
Transcription and translation quality — **especially Korean and Japanese** — is too low to trust.
Everything downstream depends on it: an inaccurate transcript makes a useless daily log; a clumsy
translation makes an untrustworthy interpreter. **Quality is priority zero**, ahead of new surface area.

## Direction — quality first, then depth, on a pluggable pipeline
Every layer is swappable (enum + protocol; see `INTERPRETATION.md`), so raising quality = swapping in a
better provider, not a rewrite.

**Quality (now):**
- STT for ko/ja: guide users to **OpenAI `gpt-4o-transcribe`** (best of current engines); **add
  ElevenLabs Scribe** (lowest ko/ja WER + real-time). Fix Deepgram `nova-2 → nova-3`; use full Whisper
  `large-v3` (not turbo) for ko/ja.
- Translation: **DeepL** text (have). Evaluate **DeepL Voice API** (audio → translated text, ko/ja) as a
  single transcribe+translate stage.
- Validate every quality claim on **real meeting audio**, not vendor benchmarks.

**Pillar 2 depth (interpretation):**
- Compose path: STT → translate → **TTS(target)** → **virtual audio device** (on-device first).
- Then a single cloud **speech-to-speech** stage: **OpenAI `gpt-realtime-translate`** (audio-in →
  Japanese audio-out, KO→JA, ~$0.034/min); Azure "Live Interpreter" preserves the speaker's voice.
- Then the reverse direction: what I hear → my language, spoken.

**Pillar 1 depth (daily knowledge):**
- Make the daily log **structured + machine-readable** (entities, decisions, action items), not prose.
- Expose it to an agent/LLM (e.g. an MCP surface or a queryable store) so it can act on the day.
- Broaden capture beyond meetings (calendar, activity) — ambient, not meeting-triggered.

The pluggable pipeline is the enabler; the two core values are the destination.

## Positioning (competitive) — the combination, not the ingredients

A mid-2026 landscape scan: the *ingredients* are crowded, the *combination* is nearly vacant.
- **Crowded, don't lead here:** local Whisper transcription (MacWhisper, superwhisper, Aiko), cloud
  meeting notetakers (Otter, Fireflies, Fathom, tl;dv, Circleback, Fellow, Read.ai), suite-bundled AI
  (Zoom AI Companion, Teams Copilot, Notion AI), cloud interpretation (DeepL Voice, Wordly, Interprefy).
  "No bot in the call" went mainstream in late 2025 — it is **table stakes, not a moat.** Never sell
  macrec as "a Mac transcriber" or "an AI notetaker" — that benchmarks us against a field we don't lead.
- **Nearly empty — our whitespace:** macOS-native **+** fully local across the *whole* pipeline **+**
  *both* pillars in one app **+** pluggable. Closest rivals, each single-pillar: **Hyprnote/anarlog**
  (OSS local notetaker — our nearest, beat it on pipeline depth + both-pillars + product finish);
  **Apple Live Translation** (on-device but locked to Apple's own apps — we capture *any* audio);
  **Granola** (polished but hybrid — cloud summarization, so not local-first).

**The wedge (one line):** *"Your meetings and conversations never leave your Mac — and they compound into
knowledge you can work from."* Lean, in order, into: (1) **fully local as a hard guarantee** (the one
claim the whole cloud/hybrid field structurally can't match; also the enterprise/regulated angle);
(2) **the pipeline, not the note** (daily log → knowledge an LLM acts on — depth nobody local builds);
(3) **two pillars, one private app** (notetaker *and* live interpreter — our most ownable sentence);
(4) **pluggable** (local by default, opt-in cloud ceiling for quality).

**Risks to respect:** platform vendors baking it in for free (Zoom/Teams/Notion/Apple) — beat them only
on privacy + any-audio capture + the pipeline they don't build, and move while the gap is open; Hyprnote
is OSS/YC on our exact ground (win on depth + finish + speed); don't fight Granola on polish — reframe to
privacy. The whitespace is real but narrow and closing.
