# macrec — extensibility architecture (plan)

Goal: make adding a provider (STT engine, translation, TTS, …) a **small, local, declarative** change —
one descriptor + one parse function — instead of scattered edits across six places. This is the vehicle
for the gradual evolution in `VISION.md`: complexity grows by *composing*, not by rewriting.

## The problem, measured against today's code

Adding a cloud STT engine (Deepgram / OpenAI / Gladia / ElevenLabs) today touches **six** places:

1. `enum LiveEngine` — a new `case`.
2. Five parallel `switch`es on it: `title`, `isReady`, `onByDefault`, `notReadyReason`, `makeTranscriber`.
3. A **~150-line WebSocket class** (`DeepgramLiveTranscriber`, `OpenAILiveTranscriber`, …) that is ~80%
   identical: open a socket with a URL + auth header, a `receiveLoop`, `feed` → PCM16 → batch → base64
   → send, `stop`/teardown, error surfacing. The only genuinely unique parts are the **URL**, the **auth
   header**, the **audio-frame encoding**, and the **response parse**.
4. Keychain wiring (`storedKey` / `apiKey` / an `isReady` `Keychain.exists` branch).
5. Settings — a new `Section` (vendor header + engine switch + key field) and an entry in the
   credential load-mask loop and the save `creds` loop.
6. A `handle()`-parsing selftest.

Four engines have paid this tax four times. That repetition is the design smell.

## The shape: descriptor registry + reusable base + declarative Settings

### 1. A reusable streaming transcriber, driven by a small spec
Collapse the ~150-line-per-provider class into **one** `StreamingWSTranscriber: LiveTranscribing` that
runs the shared machinery, parameterized by a value that captures only what differs:

```swift
struct StreamingSTTSpec {
    let makeURL:  (_ lang: String, _ hints: [String]) -> URL
    let headers:  [String: String]                       // ["xi-api-key": key] | ["Authorization": "Token \(key)"]
    let initFrames: [String]                              // config frames to send on open (OpenAI needs one; others none)
    let audioFrame: (_ pcm16: Data) -> String             // provider-specific JSON (base64 chunk)
    let parse: (_ message: String) -> (text: String, isFinal: Bool)?   // the ONLY real per-provider logic
    let sampleRate: Double
}
```

Then each provider is ~20–30 lines: a `makeURL`, a header, an `audioFrame`, and a `parse`. The socket
lifecycle, batching, teardown, and error handling live **once**. `parse` stays a pure function — exactly
the thing the current `handle()` selftests already cover, so the tests migrate 1:1.

### 2. A provider descriptor registry replaces the enum + N switches
```swift
struct EngineDescriptor {
    let id: String              // "elevenlabs"          (was the enum raw value)
    let title: String           // "ElevenLabs ☁"
    let credentialKey: String?  // Keychain account; nil = on-device (Apple/Whisper)
    let onByDefault: Bool
    let make: (_ ctx: EngineContext) -> any LiveTranscribing   // cloud → StreamingWSTranscriber(spec); on-device → its own class
}
let liveEngines: [EngineDescriptor] = [apple, whisper, deepgram, openai, gladia, elevenlabs]
```
`isReady` becomes `credentialKey == nil || Keychain.exists(credentialKey!) || envKeyPresent(env)`, computed
once over the registry. `LiveEngine.current`, `title`, `notReadyReason`, `makeTranscriber` stop being
five switches and become registry lookups. Adding a provider = **append one descriptor**.

### 3. Settings render themselves from the registry
The cloud-engine sections are the same shape (vendor header + engine switch + key field). Generate them by
iterating `liveEngines.filter { $0.credentialKey != nil }`; the credential load-mask loop and the save
`creds` loop iterate `liveEngines.compactMap(\.credentialKey)`. Adding a provider **auto-adds** its
Settings section and credential handling — zero manual `Section`/field/loop edits.

### 4. One meta-pattern for every layer
Translation (`TranslationProvider`) and TTS (`TTSProvider`) get the same descriptor+registry treatment —
`ProviderRegistry` over a capability. "Add a provider of any layer" becomes one uniform motion. The
`INTERPRETATION.md` **stage chain** then composes the layers; the registry supplies the instances.

## Migration — gradual, behavior-preserving (never a big bang)

Each step is a small PR, guarded by the existing `handle()`/selftest + the settings snapshot:

1. **Extract `StreamingWSTranscriber` + `StreamingSTTSpec`.** Migrate **one** engine (Deepgram) to it;
   prove byte-identical behavior (its `handle()` test becomes the spec's `parse` test). No user-visible change.
2. **Migrate the other three** (OpenAI, Gladia, ElevenLabs) to specs, one PR each.
3. **Introduce `EngineDescriptor` + the registry**; replace the five `LiveEngine` switches with lookups.
   Keep `LiveEngine` as a thin `rawValue` shim during transition so prefs/tests don't churn.
4. **Make Settings iterate the registry** (sections + credential loops).
5. **Lift the same registry pattern to translation + TTS.**

## Where ElevenLabs Scribe fits (the increment in flight)

Two honest options:
- **(A) Ship Scribe now on the current pattern** (a full class), take the quality win immediately, and let
  step 2 fold it into a spec. Fastest path to better ko/ja.
- **(B) Build Scribe as the FIRST `StreamingSTTSpec`**, proving the base on a fresh provider before
  migrating the incumbents. Cleaner, slightly slower.

Recommendation: **(A)** — quality is priority zero (`VISION.md`), so land the ko/ja win, then do the
extract-base refactor with all five WebSocket engines (Scribe included) as its first beneficiaries.

## What this is NOT
Not a plugin-manifest / dynamic-loading system, not config-file-defined providers, not an abstraction over
hypothetical non-WebSocket transports. Those are speculative; this plan only removes the repetition that
*actually exists today* and makes the next provider cheap. YAGNI until a real second transport appears.
