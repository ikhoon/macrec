#!/bin/zsh
# meeting-watch.sh — detect meeting (microphone in use + Zoom/Meet) and auto record → transcribe.
# Run by the LaunchAgent. Logs to $LOGFILE.

source "${0:A:h}/config.sh"

log() { print -r -- "$(date '+%F %T')  $*" }

# Returns the meeting source on stdout: "zoom" | "meet" | "" (empty = not a recognised meeting)
meeting_source() {
  # Zoom: "CptHost" is the in-meeting helper; "zoom.us" is the main app.
  if pgrep -x CptHost >/dev/null 2>&1; then print -r -- zoom; return; fi
  if pgrep -x zoom.us >/dev/null 2>&1; then print -r -- zoom; return; fi
  # Google Meet tab in a running Chromium browser ("is running" never launches the app).
  local app urls
  for app in "Google Chrome" "Google Chrome Beta" "Arc" "Microsoft Edge" "Brave Browser"; do
    urls=$(osascript -e "if application \"$app\" is running then tell application \"$app\" to get URL of tabs of windows" 2>/dev/null) || continue
    if print -r -- "$urls" | grep -qi "meet.google.com"; then print -r -- meet; return; fi
  done
  print -r -- ""
}

mkdir -p "$AUDIO_DIR"

# One-time permission registration (non-blocking — must never hang the loop): forces
# macrec into the Screen Recording + Microphone lists so they can be enabled in Settings.
"$CAPTURE" register >/dev/null 2>&1 &

log "watcher started (strict=$STRICT_MEETING poll=${POLL}s min_on=${MIN_ON}s min_off=${MIN_OFF}s)"

recording=0
on_count=0
off_count=0
warned_perm=0
RECPID=""
START_TS=""
SOURCE=""
WAV=""

cleanup() { [[ -n "$RECPID" ]] && kill -TERM "$RECPID" 2>/dev/null; log "watcher stopping"; exit 0 }
trap cleanup INT TERM

while true; do
  # If a recording process died on its own (e.g. permission denied), recover.
  if [[ "$recording" -eq 1 ]] && ! kill -0 "$RECPID" 2>/dev/null; then
    log "⚠ capture process exited early (pid $RECPID) — likely missing Screen Recording / Microphone permission. See README."
    recording=0; RECPID=""; on_count=0
  fi

  mic=$("$CAPTURE" mic-status 2>/dev/null)

  if [[ "$recording" -eq 0 ]]; then
    if [[ "$mic" == "1" ]]; then
      src=$(meeting_source)
      if [[ "$STRICT_MEETING" -eq 1 && -z "$src" ]]; then
        on_count=0                       # mic on but no meeting app → ignore
      else
        on_count=$(( on_count + POLL ))
        if [[ "$on_count" -ge "$MIN_ON" ]]; then
          if [[ "$("$CAPTURE" perm-status 2>/dev/null)" != "1" ]]; then
            if [[ "$warned_perm" -ne 1 ]]; then
              log "⚠ meeting detected but Screen Recording / Microphone permission not granted — skipping."
              log "  Enable 'macrec' in System Settings → Privacy & Security (both lists), then:"
              log "  launchctl kickstart -k gui/$(id -u)/com.ikhoon.macrec"
              warned_perm=1
            fi
            on_count=0
          else
            warned_perm=0
            SOURCE="${src:-meeting}"
            START_TS=$(date +%Y-%m-%dT%H:%M:%S)
            slug=$(date +%Y-%m-%d-%H%M)-"$SOURCE"
            WAV="$AUDIO_DIR/$slug.wav"
            # EXCLUDE_APPS (space-separated bundle ids) → --exclude-app args (e.g. keep Spotify music out)
            exargs=()
            for b in ${=EXCLUDE_APPS}; do exargs+=(--exclude-app "$b"); done
            "$CAPTURE" --out "$WAV" $exargs >"/tmp/macrec.path" 2>>"$LOGFILE" &
            RECPID=$!
            recording=1; off_count=0
            log "▶ recording started: $WAV (source=$SOURCE pid=$RECPID)"
          fi
        fi
      fi
    else
      on_count=0
    fi
  else
    if [[ "$mic" == "0" ]]; then
      off_count=$(( off_count + POLL ))
      if [[ "$off_count" -ge "$MIN_OFF" ]]; then
        log "■ stopping (mic off ${off_count}s)"
        kill -TERM "$RECPID" 2>/dev/null
        wait "$RECPID" 2>/dev/null
        final=$(cat /tmp/macrec.path 2>/dev/null)
        [[ -z "$final" ]] && final="$WAV"
        END_TS=$(date +%Y-%m-%dT%H:%M:%S)
        if [[ -s "$final" ]]; then
          log "✎ transcribing $final"
          "$TOOLS/transcribe-and-save.sh" "$final" "$START_TS" "$END_TS" "$SOURCE" >>"$LOGFILE" 2>&1 &
        else
          log "⚠ no audio captured ($final) — skipping transcription (check permissions)"
        fi
        recording=0; RECPID=""; on_count=0; off_count=0
      fi
    else
      off_count=0
    fi
  fi

  sleep "$POLL"
done
