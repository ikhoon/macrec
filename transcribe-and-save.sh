#!/bin/zsh
# transcribe-and-save.sh <audio.wav> <start_iso> <end_iso> <source>
# Transcribe with whisper.cpp (whisper-cli) + a GGML model → write meetings/<date>-<HHMM>-<source>.md, update INDEX.md.
# (Previously used MacWhisper's mw CLI, but it was flaky/hung → replaced with the standalone whisper-cli.)

source "${0:A:h}/config.sh"

WAV="$1"; START="$2"; END="$3"; SOURCE="${4:-meeting}"

[[ -s "$WAV" ]] || { print -r -- "no audio: $WAV"; exit 1; }

# whisper-cli requires 16-bit PCM. Convert the mix WAV (float32 16kHz mono) with afconvert.
PCM="${WAV:r}.pcm16.wav"
afconvert -f WAVE -d LEI16@16000 -c 1 "$WAV" "$PCM" 2>/dev/null

print -r -- "$(date '+%F %T')  whisper-cli transcribe $WAV (${WHISPER_GGML:t}, lang=$WHISPER_LANG)"
if [[ -x "$WHISPER_CLI" && -f "$WHISPER_GGML" && -s "$PCM" ]]; then
  TXT=$("$WHISPER_CLI" -m "$WHISPER_GGML" -f "$PCM" -l "$WHISPER_LANG" -np 2>/dev/null)
else
  TXT=""
fi
rm -f "$PCM" 2>/dev/null
[[ -z "${TXT//[[:space:]]/}" ]] && TXT="_(transcription failed — check whisper-cli/model, or the audio is silent: $WAV)_"

# --- time fields (BSD date) ---
DAY=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$START" +%Y-%m-%d 2>/dev/null)
HHMM=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$START" +%H%M 2>/dev/null)
HM_S=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$START" +%H:%M 2>/dev/null)
HM_E=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$END"   +%H:%M 2>/dev/null)
s=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$START" +%s 2>/dev/null)
e=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$END"   +%s 2>/dev/null)
MINS=$(( (e - s + 30) / 60 ))

MD="$MEETINGS/$DAY-$HHMM-$SOURCE.md"
AUDIO_REL="audio/$(basename "$WAV")"

# --- optionally drop the audio ---
if [[ "$KEEP_AUDIO" -ne 1 ]]; then
  rm -f "$WAV" 2>/dev/null
  AUDIO_LINE="- Audio: _(not kept)_"
else
  AUDIO_LINE="- Audio: [$AUDIO_REL]($AUDIO_REL)"
fi

# --- write the meeting note ---
mkdir -p "$MEETINGS"
cat > "$MD" <<EOF
# $DAY $HM_S — (untitled — $SOURCE meeting)

> [meeting] Auto-transcribed with whisper-cli. Mic-in-use detected → ScreenCaptureKit recording (system audio + mic).

- When: $DAY $HM_S–$HM_E (${MINS} min)
- Source: $SOURCE
- Model: \`${WHISPER_GGML:t}\` (whisper.cpp)
$AUDIO_LINE
- Tags: #meeting #$SOURCE

## Transcript

$TXT

---
_Polish the title/summary yourself. Distill reusable knowledge into \`topics/\` and back-reference this file._
EOF

print -r -- "$(date '+%F %T')  saved: $MD (${MINS} min)"

# --- update the INDEX.md meetings table (newest first; drop the placeholder row) ---
if [[ -f "$INDEX" ]]; then
  ROW="| $DAY $HM_S | [(untitled) $SOURCE meeting](meetings/$(basename "$MD")) |"
  tmp=$(mktemp)
  awk -v row="$ROW" '
    /^## .*[Mm]eeting/ { inmt=1 }
    /_none yet_/ { next }
    { print }
    inmt && !done && /^\|---/ { print row; done=1 }
  ' "$INDEX" > "$tmp" && mv "$tmp" "$INDEX"
  print -r -- "$(date '+%F %T')  INDEX.md updated"
fi
