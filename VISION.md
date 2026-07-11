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
