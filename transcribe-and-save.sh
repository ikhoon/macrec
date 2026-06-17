#!/bin/zsh
# transcribe-and-save.sh <audio.wav> <start_iso> <end_iso> <source>
# whisper.cpp(whisper-cli) + GGML 모델로 전사 → meetings/<date>-<HHMM>-<source>.md 작성, INDEX.md 갱신.
# (예전엔 MacWhisper의 mw CLI를 썼으나 불안정/멈춤 → 자립형 whisper-cli로 교체.)

source "${0:A:h}/config.sh"

WAV="$1"; START="$2"; END="$3"; SOURCE="${4:-meeting}"

[[ -s "$WAV" ]] || { print -r -- "no audio: $WAV"; exit 1; }

# whisper-cli는 16-bit PCM을 요구한다. 믹스 WAV(float32 16kHz mono)를 afconvert로 변환.
PCM="${WAV:r}.pcm16.wav"
afconvert -f WAVE -d LEI16@16000 -c 1 "$WAV" "$PCM" 2>/dev/null

print -r -- "$(date '+%F %T')  whisper-cli transcribe $WAV (${WHISPER_GGML:t}, lang=$WHISPER_LANG)"
if [[ -x "$WHISPER_CLI" && -f "$WHISPER_GGML" && -s "$PCM" ]]; then
  TXT=$("$WHISPER_CLI" -m "$WHISPER_GGML" -f "$PCM" -l "$WHISPER_LANG" -np 2>/dev/null)
else
  TXT=""
fi
rm -f "$PCM" 2>/dev/null
[[ -z "${TXT//[[:space:]]/}" ]] && TXT="_(전사 실패 — whisper-cli/모델 확인 또는 오디오가 무음: $WAV)_"

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
  AUDIO_LINE="- 오디오: _(보관 안 함)_"
else
  AUDIO_LINE="- 오디오: [$AUDIO_REL]($AUDIO_REL)"
fi

# --- write the meeting note ---
mkdir -p "$MEETINGS"
cat > "$MD" <<EOF
# $DAY $HM_S — (제목 미정 — $SOURCE 미팅)

> [미팅] whisper-cli 자동 전사. 마이크 사용 감지 → ScreenCaptureKit 녹음(시스템음+마이크).

- 일시: $DAY $HM_S–$HM_E (${MINS}분)
- 소스: $SOURCE
- 모델: \`${WHISPER_GGML:t}\` (whisper.cpp)
$AUDIO_LINE
- 태그: #meeting #$SOURCE

## 전사 (transcript)

$TXT

---
_제목·요약은 직접 다듬으세요. 재사용할 지식은 \`topics/\`로 정제하고 이 파일을 역참조하세요._
EOF

print -r -- "$(date '+%F %T')  saved: $MD (${MINS}분)"

# --- update INDEX.md 미팅 table (newest first; drop the placeholder row) ---
if [[ -f "$INDEX" ]]; then
  ROW="| $DAY $HM_S | [(제목 미정) $SOURCE 미팅](meetings/$(basename "$MD")) |"
  tmp=$(mktemp)
  awk -v row="$ROW" '
    /^## .* 미팅/ { inmt=1 }
    /_아직 없음_/ { next }
    { print }
    inmt && !done && /^\|---/ { print row; done=1 }
  ' "$INDEX" > "$tmp" && mv "$tmp" "$INDEX"
  print -r -- "$(date '+%F %T')  INDEX.md updated"
fi
