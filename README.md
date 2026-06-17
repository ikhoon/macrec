# meeting-recorder

An always-on macOS **menu-bar app** (with a CLI) that continuously records your **microphone + system audio**, splits the day into **hourly segments**, and **transcribes** the hours that actually contain speech using `whisper.cpp` with **Voice Activity Detection**. Transcripts land as timestamped Markdown in a folder you choose.

Meeting boundaries are intentionally *not* detected — you get clean hourly transcripts and let an LLM segment/curate them later.

## How it works

```
menu-bar app (launchd, at login) ──► continuous capture
   • system audio : ScreenCaptureKit (excludes chosen apps, e.g. Spotify)
   • microphone   : a SEPARATE AVCaptureSession  ← key: capturing both via SCK
                                                    hijacks the default output
   └─ every hour, on the hour ──► rotate segment
        speech this hour (mic OR system ≥ N s)?
          yes → mix → whisper-cli (VAD + suppress non-speech) → transcripts/YYYY-MM-DD-HHMM.md (+ kept WAV)
          no  → discard
   └─ display sleeps → SCStream dies (-3815) → auto-rebuild on wake (mic keeps running)
   └─ daily ──► delete audio/transcripts past their retention window
```

Design notes (each one is a bug we actually hit):

- **Mic is captured via a separate `AVCaptureSession`, not ScreenCaptureKit.** Capturing system audio *and* mic through SCK (or forcing a device sample rate) makes macOS build an aggregate device that steals the default output — you stop hearing anything. Keeping mic on its own path leaves the output untouched.
- **VAD (silero) + `--suppress-nst`** skip silence/noise, so transcripts don't fill up with whisper's silence hallucinations ("Thank you", subtitle credits, etc.).
- **Display sleep kills the SCStream** (`-3815 Failed to find any displays`). The engine listens for the stream stopping and for wake notifications and rebuilds the stream automatically.
- **System audio is the digital mix before your DAC**, so transcription quality is unaffected by analog/output-device noise.

## Install

```bash
cd ~/src/meeting-recorder
./install.sh
```

`install.sh` will:
1. create a **stable self-signed code-signing certificate** once (`make-signing-cert.sh`),
2. build `MeetingCapture.swift` → `MeetingCapture.app`,
3. **sign it with that cert** (so TCC permissions survive every rebuild — see below),
4. install a per-user LaunchAgent that launches the app at login.

### One-time permissions

Grant these once in **System Settings → Privacy & Security**:
- **Screen & System Audio Recording** → enable `meeting-capture`
- **Microphone** → enable `meeting-capture`

> Why Screen Recording for an audio tool? macOS only exposes **system-audio capture** through ScreenCaptureKit, which is gated by that permission. No screen content is recorded — the capture uses a throwaway 2×2-pixel video stream and writes audio only.

If switching from an old ad-hoc build, reset stale grants once, then re-grant:
```bash
tccutil reset ScreenCapture com.ikhoon.meeting-capture
tccutil reset Microphone    com.ikhoon.meeting-capture
launchctl kickstart -k gui/$(id -u)/com.ikhoon.meeting-recorder
```
After this, **rebuilds keep the grant** — the code-signing *designated requirement* references the certificate + bundle id, not the per-build code hash. Don't delete/regenerate the cert (back up `~/.config/meeting-recorder/MeetingCaptureSign.p12`).

## Settings (menu-bar → Settings…)

Stored in `UserDefaults` (suite `com.ikhoon.MeetingRecorder`); saving restarts the engine immediately.

| Setting | Default |
|---|---|
| Segment length (on the hour) | 1 hour (15 m / 30 m / 1 h / 2 h) |
| Transcription language | Auto-detect |
| Min. speech to transcribe | 5 s |
| Remove noise/silence (VAD) | on |
| Keep audio (WAV) too | on |
| Keep audio for | 30 days |
| Keep transcripts for | Unlimited |
| Excluded apps | `com.spotify.client` (add more — incl. pick from running apps) |
| Save transcripts to | `~/src/LINE/work/transcripts` |

Menu actions: **Transcribe now** (flush the current segment without waiting for the hour), **Pause / Resume**, **Open transcripts folder**, **Quit**.

Power users / headless runs can override any setting via `MR_*` environment variables (precedence: UserDefaults → env → default).

## CLI

The same binary is a CLI:

```bash
APP=MeetingCapture.app/Contents/MacOS/meeting-capture
$APP mic-status          # 1 if the default input device is in use
$APP perm-status         # 1 if Screen Recording + Microphone are granted
$APP config              # print the resolved settings
$APP request-permission  # trigger/register the TCC prompts
$APP --out out.wav --duration 20 [--exclude-app <bundleid>] [--no-mic]   # one-shot capture
$APP engine              # run the continuous engine headless (no menu bar)
```

## Files

| File | Role |
|---|---|
| `MeetingCapture.swift` | the whole app: capture engine, transcriber, menu-bar UI, settings, CLI |
| `install.sh` / `uninstall.sh` | build + sign + (un)install the LaunchAgent |
| `make-signing-cert.sh` | create the stable self-signed signing certificate (once) |
| `config.sh` | defaults that seed the LaunchAgent's `MR_*` environment |
| `live-diagnose.sh` | run during a meeting to check mic/system levels + a quick transcript |
| `verify-capture.sh` | controlled capture self-test (plays a known file) |

## Privacy

Records your mic **and** other participants' audio. Use only for meetings you're allowed to record (recording a conversation you take part in is legal in both KR and JP). Audio/transcripts stay **local** — nothing is uploaded.

## Requirements

macOS 15+ (built for macOS 26); `whisper-cli` (whisper.cpp: `brew install whisper-cpp`); GGML models in `~/whisper-models/` — `ggml-large-v3-turbo.bin` (transcription) and `ggml-silero-v5.1.2.bin` (VAD).
