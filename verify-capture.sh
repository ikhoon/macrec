#!/bin/zsh
# verify-capture.sh — run BY LAUNCHD (one-shot) so meeting-capture uses its own TCC identity.
# Checks permission, captures ~7s while playing a known test file, reports peaks + transcript.
source "${0:A:h}/config.sh"

OUT=/tmp/mr-verify
JFK=/opt/homebrew/share/whisper-cpp/jfk.wav
[[ -f "$JFK" ]] || JFK=$(find /opt/homebrew -name jfk.wav 2>/dev/null | head -1)

{
  echo "=== meeting-recorder verify @ $(date '+%F %T') ==="
  ps=$("$CAPTURE" perm-status 2>&1)
  echo "perm-status (launchd identity): $ps"
  if [[ "$ps" != "1" ]]; then
    echo "RESULT: ❌ meeting-capture is NOT granted yet. Enable it in System Settings →"
    echo "  Privacy & Security → Screen & System Audio Recording AND Microphone, then re-run."
    echo "=== done ==="
    exit 0
  fi

  echo "permission OK — capturing 7s while playing $JFK …"
  "$CAPTURE" --out $OUT.wav --duration 7 2>$OUT.caperr &
  CAP=$!
  afplay "$JFK" 2>/dev/null &
  AP=$!
  wait $CAP
  kill $AP 2>/dev/null

  echo "--- capture stats ---"
  grep -E "stats |SILENT" $OUT.caperr
  echo "--- transcript of the mix (whisper-cli) ---"
  if [[ -x "$WHISPER_CLI" && -f "$WHISPER_GGML" && -s "$OUT.wav" ]]; then
    afconvert -f WAVE -d LEI16@16000 -c 1 "$OUT.wav" "$OUT.pcm.wav" 2>/dev/null
    "$WHISPER_CLI" -m "$WHISPER_GGML" -f "$OUT.pcm.wav" -l "$WHISPER_LANG" -np 2>/dev/null
  else
    echo "(whisper-cli/모델 없음 — 전사 생략)"
  fi
  echo
  echo "RESULT: if 'stats sys' peak > 0 and the JFK line ('ask not what your country…') appears,"
  echo "  system audio capture WORKS. If peak≈0 / SILENT, it's an output-routing issue."
  echo "=== done ==="
} > $OUT.result 2>&1

rm -f $OUT.wav $OUT.sys.wav $OUT.mic.wav $OUT.caperr $OUT.pcm.wav 2>/dev/null
