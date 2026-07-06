#!/bin/zsh
# live-diagnose.sh — live diagnosis to run DURING an actual meeting.
#   Verifies that sys (them) and mic (me) audio are really captured in a real meeting.
#   Runs macrec via launchd (= under its own TCC identity, not the terminal's) to capture N seconds,
#   then shows per-track peak/RMS and a quick whisper-cli transcript. (The flaky mw is not used.)
#
# Usage:  ./live-diagnose.sh [secs=20] [lang=auto|ko|ja|en]
#   Run during a meeting; while it captures, have the other side talk and say a few words yourself.

source "${0:A:h}/config.sh"

# Also keep the result in a file (screen output + file at once) — not deleted when done.
RESULT_LOG=/tmp/macrec-diagnose-last.txt
exec > >(tee "$RESULT_LOG") 2>&1

SECS="${1:-20}"
LANG="${2:-auto}"
BASE=/tmp/macrec-live
LABEL=com.ikhoon.macrec-live-diagnose
WC=/opt/homebrew/bin/whisper-cli

# GGML model for whisper-cli (separate from the mw models). Prefer the fast turbo.
MODEL="${WHISPER_GGML:-$HOME/whisper-models/ggml-large-v3-turbo.bin}"
[[ -f "$MODEL" ]] || MODEL=$(/usr/bin/find "$HOME/Library/Application Support/MacWhisper/models" -name "ggml*turbo*.bin" 2>/dev/null | head -1)
[[ -f "$MODEL" ]] || MODEL=$(/usr/bin/find "$HOME/Library/Application Support/MacWhisper/models" -name "ggml-large-v3.bin" 2>/dev/null | head -1)

echo "=== macrec LIVE diagnosis @ $(date '+%F %T') ==="
echo "capture=$CAPTURE"
echo "whisper-cli model=$MODEL"
[[ -x "$WC" && -f "$MODEL" ]] || { echo "❌ whisper-cli or the GGML model is missing. (check models with 'mw models')"; }

# 1) capture N seconds via launchd (--keep-temp keeps the sys/mic tracks, --duration = clean exit = valid header)
rm -f ${BASE}*(N) 2>/dev/null   # (N)=NULL_GLOB: no error when nothing matches
launchctl submit -l "$LABEL" -o $BASE.out -e $BASE.err -- \
  "$CAPTURE" --out $BASE.wav --duration "$SECS" --keep-temp 2>/dev/null
echo "▶ capturing ${SECS}s (launchd)… have the other side talk now, and say a few words yourself."

# 2) wait for completion ('done →' or timeout)
t=0; limit=$(( SECS + 20 ))
while (( t < limit )); do
  sleep 1; t=$(( t + 1 ))
  grep -q "done →\|error:" $BASE.err 2>/dev/null && break
done
launchctl remove "$LABEL" 2>/dev/null

# 3) permission / capture log
echo "--- capture log ---"
grep -E "perm|error:|recording →|stats |SILENT|done →" $BASE.err 2>/dev/null || echo "(no log)"
if grep -q "permission not granted\|error:" $BASE.err 2>/dev/null; then
  echo "RESULT: ❌ permission/capture error — check System Settings → Screen & System Audio Recording / Microphone, then retry."
  rm -f ${BASE}*(N) 2>/dev/null; echo "=== done ==="; exit 0
fi

# 4) per-track peak/RMS (measured directly from float32)
echo "--- per-track amplitude (the key check) ---"
python3 - "$BASE" <<'PY'
import sys, array, os, math
base=sys.argv[1]
for tag, fn in [("sys(them)", base+".sys.wav"), ("mic(me)  ", base+".mic.wav")]:
    if not os.path.exists(fn): print(f"{tag}: (file missing — capture failed)"); continue
    sz=os.path.getsize(fn); n=max(0,(sz-4096)//4)
    with open(fn,'rb') as f:
        f.seek(4096); a=array.array('f'); a.frombytes(f.read(n*4))
    if not len(a): print(f"{tag}: (empty track)"); continue
    peak=max(max(a), -min(a)); rms=math.sqrt(sum(x*x for x in a)/len(a))
    v = "✅ voice captured" if peak>0.05 else ("⚠ very weak (near-silent)" if peak>0.005 else "❌ completely silent")
    print(f"{tag}: peak={peak:.3f} rms={rms:.4f}  {v}")
PY

# 5) quick per-track transcript (whisper-cli + GGML)
if [[ -x "$WC" && -f "$MODEL" ]]; then
  for trk in sys mic; do
    f=$BASE.$trk.wav
    [[ -f "$f" ]] || continue
    /usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 "$f" "$BASE.$trk.pcm.wav" 2>/dev/null
    echo "--- $trk transcript (whisper-cli, lang=$LANG) ---"
    "$WC" -m "$MODEL" -f "$BASE.$trk.pcm.wav" -l "$LANG" -np 2>/dev/null
  done
fi

echo
echo "How to read the RESULT:"
echo "  • sys(them) peak>0 + their speech is transcribed → system-audio capture works"
echo "  • sys peak≈0 while the other side was talking → output-routing problem"
echo "    (switch the Zoom speaker output device / system default output to 'Mac Studio Speakers' and retry)"
echo "  • mic(me) peak≈0 → Zoom is muted, or an input-device problem (check the default input device)"
rm -f ${BASE}*(N) 2>/dev/null
echo "=== done ==="
