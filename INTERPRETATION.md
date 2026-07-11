# Live interpretation — layered, pluggable pipeline

Goal: I speak Korean; the remote party on my call hears Japanese. And, more broadly, a **composable
pipeline** where each capability is a layer you can swap or stack — the Decorator shape — so a cloud
implementation of any layer plugs in later without rewiring the others.

## The pipeline as a chain of stages (Decorator)

One unit flows through the pipeline — an **`Utterance`** (a speaker's evolving line): source text +
language, `isFinal`, and optional enrichments (translation, spoken?). Stages are **sinks that wrap the
next sink**, enrich or act, then forward:

```
Transcriber(source) ─▶ TranslatingStage ─▶ SpeakingStage ─▶ OverlayStage(terminal sink)
                        adds translation    TTS the target   draws the overlay
                                             + routes audio
```

`LiveCaptions` builds the chain from config — adding a capability is composition, never editing another
stage:

```swift
var sink: UtteranceSink = OverlayStage(window)          // always the terminal renderer
if interpretationOn { sink = SpeakingStage(tts, out, next: sink) }
if translateOn      { sink = TranslatingStage(translator, next: sink) }
// transcribers emit Utterances into `sink` (the head of the chain)
```

Each stage is independently selftestable (feed an `Utterance`, assert the forwarded/emitted result). The
existing `apply` / `translateNewSentences` / `render` become stages; the migration is behavior-preserving
and incremental, guarded by per-stage selftests + the overlay snapshot.

## Every layer is pluggable (enum + protocol) — cloud drops in later

The exact pattern already used by `LiveEngine` (5 transcribers) and `TranslationProvider` (Apple + DeepL):
a protocol for the capability, an enum of providers with `title` / `isReady` / a pure "which one" decision
that demotes to a safe default when a credential is missing.

| Layer        | Protocol             | On-device now              | Cloud later (pluggable)                    |
|--------------|----------------------|----------------------------|--------------------------------------------|
| Transcribe   | `LiveTranscribing`   | Apple, Whisper             | Deepgram / OpenAI / Gladia (already)       |
| Translate    | `LiveTranslating`    | Apple Translation          | DeepL (already); more later                |
| **Speak**    | `SpeechSynthesizing` | Apple `AVSpeechSynthesizer`| OpenAI / ElevenLabs / Google TTS           |
| **Interpret**| (composition)        | transcribe→translate→speak | a single cloud **speech-to-speech** stage  |

Two ways a cloud interpreter plugs in, both supported by the chain:
1. **Swap one layer** — a `CloudSpeechSynthesizer: SpeechSynthesizing` replaces Apple TTS; the rest is
   unchanged.
2. **Replace several stages with one** — a cloud service that takes source audio and returns target
   audio is just a stage that consumes early and emits late, short-circuiting translate+speak. The chain
   builder chooses it when selected.

Decision (chosen): first version uses **on-device `AVSpeechSynthesizer`** and routes to a **virtual audio
device**; both are behind the protocol / a provider enum so cloud versions are additive.

## Audio routing — the crux (chosen: virtual audio device)

The Japanese TTS must reach the meeting so the remote hears it. Chosen approach: macrec plays the TTS into
a **virtual output device** (BlackHole-style); the user selects that device as their microphone in
Zoom / Meet / Teams. macrec does not ship a driver — it detects an installed virtual device and offers it
as the "interpretation output."

```
my mic ─▶ transcribe(ko) ─▶ translate(ja) ─▶ AVSpeechSynthesizer(ja)
                                                     │
                                             [virtual audio device]  ◀─ user picks this as their mic
                                                     │
                                              Zoom / Meet / Teams ─▶ remote hears Japanese
```

Mechanics: enumerate output devices (Core Audio `kAudioHardwarePropertyDevices`), let the user pick one in
Settings, and render TTS through an `AVAudioEngine` whose output node is set to that device
(`AUHAL` / `kAudioOutputUnitProperty_CurrentDevice`). The user mutes their real mic in the call so only the
interpreted voice goes out.

**Verification boundary:** that the *remote party hears it* can only be confirmed with a virtual device
installed + a real call + a second person — hand that check to a human. In-repo we verify: the chosen
device is honored, TTS is produced, and the stage logic (speak once per final utterance, correct target
language) via selftests + an audible local run.

## Phased plan

1. **Foundation** (safe, additive) — `Utterance`, `UtteranceSink`, `SpeechSynthesizing` +
   `AppleSpeechSynthesizer`, `SpeakingStage`, an `InterpreterProvider`-style enum, and the pure
   "speak-once-per-final-utterance" decision, all selftested. Does not yet replace the caption path.
2. **Wire + Settings** — migrate the caption path onto the chain (behavior-preserving); add an
   Interpretation toggle + source/target + output-device picker; run the overlay live.
3. **Routing** — render TTS to the selected virtual device; document the meeting-app mic setup.
4. **Cloud plug-ins** — a `SpeechSynthesizing` cloud provider, and/or a single cloud speech-to-speech
   stage, behind the same enum+protocol pattern. No changes to stages that don't use it.

Latency: chunk on sentence boundaries (the translation layer already emits per-sentence), speak finals.
