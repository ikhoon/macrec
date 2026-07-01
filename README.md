# macrec

> Always-on macOS meeting recorder — `mac` + `rec`, a sibling of `maccal` / `macmail`.

An always-on macOS **menu-bar app** (with a CLI) that continuously records your **microphone + system audio**, splits the day into **hourly segments**, and **transcribes** the hours that actually contain speech using `whisper.cpp` with **Voice Activity Detection**. Transcripts land as timestamped Markdown in a folder you choose.

Meeting boundaries are intentionally *not* detected — you get clean hourly transcripts and let an LLM segment/curate them later.

> The repo/dir is still `meeting-recorder` and internal identifiers (bundle id `com.ikhoon.meeting-capture`, the executable `meeting-capture`) are unchanged — only the **product name** is macrec.

## How it works

```
menu-bar app (login item / launchd) ──► continuous capture
   • system audio : ScreenCaptureKit (excludes chosen apps, e.g. Spotify)
   • microphone   : a SEPARATE AVCaptureSession  ← key: capturing both via SCK
                                                    hijacks the default output
   └─ every hour, on the hour ──► rotate segment
        speech this hour (mic OR system ≥ N s)?
          yes → mix → whisper-cli (VAD + suppress non-speech) → transcripts/YYYY-MM-DD-HHMM.md (+ kept WAV)
          no  → discard
   └─ display sleeps / screen locks → suspend capture; wake/unlock → rebuild
   └─ daily ──► delete audio/transcripts past their retention window
```

Design notes (each one is a bug we actually hit):

- **Mic is captured via a separate `AVCaptureSession`, not ScreenCaptureKit.** Capturing system audio *and* mic through SCK (or forcing a device sample rate) makes macOS build an aggregate device that steals the default output — you stop hearing anything. Keeping mic on its own path leaves the output untouched.
- **VAD (silero) + `--suppress-nst`** skip silence/noise, so transcripts don't fill up with whisper's silence hallucinations ("Thank you", subtitle credits, etc.).
- **Display sleep kills the SCStream** (`-3815 Failed to find any displays`). The engine suspends on sleep/lock and rebuilds the stream automatically on wake/unlock.
- **System audio is the digital mix before your DAC**, so transcription quality is unaffected by analog/output-device noise.
- **Speaker labels**: mic → `나`, system audio → `상대`, merged by timestamp. Transcripts are auto-titled from the overlapping **calendar** event (prefers ones with a Zoom/Meet/Teams link).

## Install

Three paths — pick one.

### Homebrew (recommended)

```bash
brew install ikhoon/tap/macrec
```

Then launch it and grant permissions (see [One-time permissions](#one-time-permissions)):

```bash
open "$(brew --prefix)/opt/macrec/macrec.app"      # menu-bar app
macrec config                                       # the CLI is on your PATH too
```

Apple Silicon only. Installing via brew **avoids the Gatekeeper "Open Anyway" step** (Homebrew's
download isn't quarantined). `brew upgrade` pulls new releases. First run downloads the model.

### A) Download the app (self-contained, no Homebrew)

Grab **`macrec.zip`**, unzip, drag **`macrec.app`** to `/Applications`, and launch it.

- The app **bundles a self-contained `whisper-cli`** (built static, Metal embedded — no `/opt/homebrew` dependency) and the **silero VAD** model.
- On first run it **downloads the transcription model** (default *Large v3 Turbo*, ~1.6 GB) to `~/Library/Application Support/MeetingRecorder/models/`; the menu shows `⤓ Downloading model… %`. You can change the model in Settings (see below).
- First launch is blocked by Gatekeeper (self-signed): **System Settings → Privacy & Security → “Open Anyway”** once.
- It registers itself as a **Login Item** on first run (24/7 autostart); toggle in Settings.

### B) Build from source (developer machine)

```bash
cd ~/src/meeting-recorder
./install.sh
```

`install.sh` will:
1. create a **stable self-signed code-signing certificate** once (`make-signing-cert.sh`),
2. build `MeetingCapture.swift` → `macrec.app`,
3. **sign it with that cert** (so TCC permissions survive every rebuild — see below),
4. install a per-user **LaunchAgent** that launches the app at login (with `KeepAlive`).

> On a machine with the dev LaunchAgent, the app leaves autostart to launchd and the “Start at login” toggle shows as managed.

### Building a distributable

```bash
./package.sh        # → dist/macrec.zip
```

`package.sh` builds `whisper.cpp` from source **static** (`BUILD_SHARED_LIBS=OFF`, `GGML_BACKEND_DL=OFF`, Metal embedded) so the bundled `whisper-cli` has **zero `/opt/homebrew` dependencies**, bundles it + the VAD model into a self-signed `macrec.app`, and zips it. Needs Xcode Command Line Tools (`swiftc`/`cmake`) on the build machine; the resulting app needs **neither Homebrew nor a pre-installed model** on the target.

### One-time permissions

Grant these once in **System Settings → Privacy & Security**:
- **Screen & System Audio Recording** → enable `meeting-capture`
- **Microphone** → enable `meeting-capture`
- **Calendar** → enable `macrec` (to title transcripts from meeting events)

> Why Screen Recording for an audio tool? macOS only exposes **system-audio capture** through ScreenCaptureKit, which is gated by that permission. No screen content is recorded — the capture uses a throwaway 2×2-pixel video stream and writes audio only.

The code-signing **designated requirement** references the certificate + bundle id, not the per-build code hash, so **rebuilds keep the grant** (and the Login Item stays registered). Don't delete/regenerate the cert (back up `~/.config/meeting-recorder/MeetingCaptureSign.p12`). If switching from an old ad-hoc build, reset stale grants once:
```bash
tccutil reset ScreenCapture com.ikhoon.meeting-capture
tccutil reset Microphone    com.ikhoon.meeting-capture
launchctl kickstart -k gui/$(id -u)/com.ikhoon.meeting-recorder
```

## Settings (menu-bar → Settings…)

Stored in `UserDefaults` (suite `com.ikhoon.MeetingRecorder`); saving restarts the engine immediately.

| Setting | Default |
|---|---|
| Segment length (on the hour) | 1 hour (15 m / 30 m / 1 h / 2 h) |
| Transcription language | Auto-detect |
| **Transcription model** | Large v3 Turbo (turbo-q5_0 / large-v3 / medium / small / base / tiny) |
| Min. speech to transcribe | 5 s |
| Remove noise/silence (VAD) | on |
| Title transcripts from calendar | on |
| **Start at login (24/7)** | on (distributed app; managed by LaunchAgent on dev machines) |
| Keep audio (WAV) too | on |
| Keep audio for | 30 days |
| Keep transcripts for | Unlimited |
| Excluded apps | `com.spotify.client` (add more — incl. pick from running apps) |
| Save transcripts to | `~/Documents/macrec/transcripts` |
| Save audio to | `~/Documents/macrec/audio` |

Changing the model downloads the new one on demand (models coexist by filename, so switching back never re-downloads). Menu actions: **Transcribe now**, **Pause / Resume**, **Open transcripts folder**, **Quit**.

Power users / headless runs can override any setting via `MR_*` environment variables (e.g. `MR_WHISPER_MODEL`, `MR_MODEL_URL`; precedence: UserDefaults → env → default).

## CLI

The same binary is a CLI:

```bash
APP=/Applications/macrec.app/Contents/MacOS/meeting-capture
$APP mic-status          # 1 if the default input device is in use
$APP perm-status         # 1 if Screen Recording + Microphone are granted
$APP config              # print resolved settings (model, paths, loginItem status)
$APP request-permission  # trigger/register the TCC prompts
$APP --out out.wav --duration 20 [--exclude-app <bundleid>] [--no-mic]   # one-shot capture
$APP engine              # run the continuous engine headless (no menu bar)
```

## Files

| File | Role |
|---|---|
| `MeetingCapture.swift` | the whole app: capture engine, model store, transcriber, menu-bar UI, settings, login item, CLI |
| `install.sh` | build + sign + install to `/Applications/macrec.app` + LaunchAgent (dev machine) |
| `package.sh` | build static `whisper-cli` + bundle into a self-contained, self-signed `macrec.app` → `dist/macrec.zip` |
| `make-signing-cert.sh` | create the stable self-signed signing certificate (once) |
| `config.sh` | defaults that seed the LaunchAgent's `MR_*` environment |
| `make-icon.swift` | generate the colorful app icon |
| `live-diagnose.sh` / `verify-capture.sh` | mic/system level checks + capture self-test |

## Privacy

Records your mic **and** other participants' audio. Use only for meetings you're allowed to record (recording a conversation you take part in is legal in both KR and JP). Audio/transcripts and the model all stay **local** — the only network access is the one-time model download from Hugging Face.

## Requirements

- **End users (download path):** macOS 15+ (built for macOS 26). Nothing else — `whisper-cli` and the VAD are bundled; the model downloads on first run.
- **Building from source:** Xcode Command Line Tools (`swiftc`, and `cmake` for `package.sh`). `install.sh`'s dev build can also use a Homebrew `whisper-cli` + `~/whisper-models/` if present (it falls back to those when not running the bundled app).
