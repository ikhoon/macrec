#!/bin/zsh
# live-diagnose.sh — 실제 미팅 "중에" 돌리는 라이브 진단.
#   실 미팅에서 sys(상대)·mic(나) 오디오가 정말 캡처되는지 확인한다.
#   meeting-capture 를 launchd 로 띄워(= 터미널이 아닌 자기 TCC 정체로) N초 캡처한 뒤,
#   트랙별 peak/RMS 와 whisper-cli 간이 전사를 보여준다. (불안정한 mw 는 안 씀)
#
# 사용법:  ./live-diagnose.sh [초=20] [언어=auto|ko|ja|en]
#   미팅 중 실행하고, 캡처되는 동안 "상대가 말하게 + 본인도 한두 마디" 하세요.

source "${0:A:h}/config.sh"

# 결과를 파일로도 남긴다 (화면 출력 + 파일 동시) — 끝나도 안 지움.
RESULT_LOG=/tmp/mr-diagnose-last.txt
exec > >(tee "$RESULT_LOG") 2>&1

SECS="${1:-20}"
LANG="${2:-auto}"
BASE=/tmp/mr-live
LABEL=com.ikhoon.mr-live-diagnose
WC=/opt/homebrew/bin/whisper-cli

# whisper-cli 용 GGML 모델 (mw 모델과 별개). 빠른 turbo 우선.
MODEL="${WHISPER_GGML:-$HOME/whisper-models/ggml-large-v3-turbo.bin}"
[[ -f "$MODEL" ]] || MODEL=$(/usr/bin/find "$HOME/Library/Application Support/MacWhisper/models" -name "ggml*turbo*.bin" 2>/dev/null | head -1)
[[ -f "$MODEL" ]] || MODEL=$(/usr/bin/find "$HOME/Library/Application Support/MacWhisper/models" -name "ggml-large-v3.bin" 2>/dev/null | head -1)

echo "=== meeting-recorder LIVE 진단 @ $(date '+%F %T') ==="
echo "capture=$CAPTURE"
echo "whisper-cli model=$MODEL"
[[ -x "$WC" && -f "$MODEL" ]] || { echo "❌ whisper-cli 또는 GGML 모델이 없습니다. (mw models 로 모델 확인)"; }

# 1) launchd 로 N초 캡처 (--keep-temp 로 sys/mic 트랙 보존, --duration 로 클린 종료=헤더 정상)
rm -f ${BASE}*(N) 2>/dev/null   # (N)=NULL_GLOB: 매치 없어도 에러 안 남
launchctl submit -l "$LABEL" -o $BASE.out -e $BASE.err -- \
  "$CAPTURE" --out $BASE.wav --duration "$SECS" --keep-temp 2>/dev/null
echo "▶ ${SECS}초 캡처 중 (launchd)… 지금 상대가 말하게 하고, 본인도 한두 마디 하세요."

# 2) 완료 대기 ('done →' 또는 타임아웃)
t=0; limit=$(( SECS + 20 ))
while (( t < limit )); do
  sleep 1; t=$(( t + 1 ))
  grep -q "done →\|error:" $BASE.err 2>/dev/null && break
done
launchctl remove "$LABEL" 2>/dev/null

# 3) 권한/캡처 자체 로그
echo "--- capture 로그 ---"
grep -E "perm|error:|recording →|stats |SILENT|done →" $BASE.err 2>/dev/null || echo "(로그 없음)"
if grep -q "permission not granted\|error:" $BASE.err 2>/dev/null; then
  echo "RESULT: ❌ 권한/캡처 오류 — System Settings → 화면 및 시스템 오디오 녹화 / 마이크 확인 후 재시도."
  rm -f ${BASE}*(N) 2>/dev/null; echo "=== done ==="; exit 0
fi

# 4) 트랙별 peak/RMS (float32 직접 측정)
echo "--- 트랙별 진폭 (핵심) ---"
python3 - "$BASE" <<'PY'
import sys, array, os, math
base=sys.argv[1]
for tag, fn in [("sys(상대)", base+".sys.wav"), ("mic(나) ", base+".mic.wav")]:
    if not os.path.exists(fn): print(f"{tag}: (파일 없음 — 캡처 실패)"); continue
    sz=os.path.getsize(fn); n=max(0,(sz-4096)//4)
    with open(fn,'rb') as f:
        f.seek(4096); a=array.array('f'); a.frombytes(f.read(n*4))
    if not len(a): print(f"{tag}: (빈 트랙)"); continue
    peak=max(max(a), -min(a)); rms=math.sqrt(sum(x*x for x in a)/len(a))
    v = "✅ 음성 잡힘" if peak>0.05 else ("⚠ 매우 약함(거의 무음)" if peak>0.005 else "❌ 완전 무음")
    print(f"{tag}: peak={peak:.3f} rms={rms:.4f}  {v}")
PY

# 5) 트랙별 간이 전사 (whisper-cli + GGML)
if [[ -x "$WC" && -f "$MODEL" ]]; then
  for trk in sys mic; do
    f=$BASE.$trk.wav
    [[ -f "$f" ]] || continue
    /usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 "$f" "$BASE.$trk.pcm.wav" 2>/dev/null
    echo "--- $trk 전사 (whisper-cli, lang=$LANG) ---"
    "$WC" -m "$MODEL" -f "$BASE.$trk.pcm.wav" -l "$LANG" -np 2>/dev/null
  done
fi

echo
echo "RESULT 판독:"
echo "  • sys(상대) peak>0 + 상대 말이 전사되면 → 시스템오디오 캡처 정상"
echo "  • sys peak≈0 인데 상대가 말하고 있었다면 → 출력 라우팅 문제"
echo "    (Zoom 스피커 출력 장치 / 시스템 기본 출력 장치를 'Mac Studio 스피커'로 바꿔 재시도)"
echo "  • mic(나) peak≈0 이면 → Zoom 음소거 또는 입력 장치 문제 (기본 입력 장치 확인)"
rm -f ${BASE}*(N) 2>/dev/null
echo "=== done ==="
