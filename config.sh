# config.sh — shared settings, sourced by the scripts (zsh)
#
# 이 도구는 이제 독립 위치(~/src/meeting-recorder)에 살고,
# 산출물(회의록·오디오)만 별도의 노트 DB(work 레포)에 떨어진다.

# 이 스크립트들이 있는 디렉토리 (= 도구 설치 위치)
TOOLS="${${(%):-%x}:A:h}"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH"

# --- 산출물(회의록/오디오)이 떨어질 노트 DB 루트 (환경변수로 override 가능) ---
: ${OUTPUT_ROOT:="$HOME/src/LINE/work"}        # ← 회의록이 저장될 DB (분리된 출력 대상)

# --- 캡처/전사 바이너리 ---
: ${INSTALL_APP:="/Applications/MeetingRecorder.app"}   # 설치(실행) 위치 — Finder/Applications에 노출
: ${CAPTURE:="$INSTALL_APP/Contents/MacOS/meeting-capture"}  # 캡처 바이너리(.app 내부 = 안정적 TCC 정체)
: ${BUNDLE_ID:="com.ikhoon.meeting-capture"}   # 고정 — 절대 바꾸지 말 것 (TCC DR의 identifier)
: ${SIGN_ID:="MeetingCaptureSign"}             # 코드서명 인증서 이름 (make-signing-cert.sh가 생성)

# 전사: MacWhisper의 mw(CLI) 대신 whisper.cpp의 whisper-cli + GGML 모델을 직접 사용 (안정적)
: ${WHISPER_CLI:="/opt/homebrew/bin/whisper-cli"}
: ${WHISPER_GGML:="$HOME/whisper-models/ggml-large-v3-turbo.bin"}   # 빠른 turbo 우선
: ${VAD_MODEL:="$HOME/whisper-models/ggml-silero-v5.1.2.bin"}       # silero VAD — 무음/잡음 구간 제거(환각 방지)
: ${WHISPER_LANG:="auto"}                      # ko|ja|en|auto

# --- 산출물 경로 (OUTPUT_ROOT 기준) ---
: ${MEETINGS:="$OUTPUT_ROOT/meetings"}
: ${AUDIO_DIR:="$MEETINGS/audio"}
: ${INDEX:="$OUTPUT_ROOT/INDEX.md"}
: ${LOGFILE:="$TOOLS/meeting-recorder.log"}    # 로그는 도구 위치에 (런타임 상태)

# --- 감지/동작 노브 (환경변수로 override 가능) ---
: ${STRICT_MEETING:=1}   # 1: Zoom/Meet 감지될 때만 녹음; 0: 마이크 켜지면 무조건
: ${POLL:=3}             # 마이크 상태 폴링 간격(초)
: ${MIN_ON:=6}           # 녹음 시작 전 마이크가 켜져 있어야 하는 시간(초) — blip 무시
: ${MIN_OFF:=8}          # 녹음 정지 전 마이크가 꺼져 있어야 하는 시간(초)
: ${KEEP_AUDIO:=1}       # 1: 믹스 WAV를 meetings/audio/에 보관; 0: 전사 후 삭제

# --- 녹음에서 오디오를 제외할 앱 (공백 구분 bundle id) ---
# 음악(Spotify)이 미팅 녹음에 섞이지 않게 한다. (SCK는 앱 단위로 오디오 제외)
: ${EXCLUDE_APPS:="com.spotify.client"}

# --- 연속 녹음/전사 엔진 (앱 모드. Swift 앱이 MR_* 환경변수로 읽음) ---
: ${SEGMENT_SECONDS:=3600}                       # 시간 단위 회전 (초). 1시간=3600
: ${VOICE_MIN_SECONDS:=5}                         # 이만큼(초) 이상 mic 발화가 있어야 전사·보관
: ${TRANSCRIPTS_DIR:="$OUTPUT_ROOT/transcripts"}  # 시간별 전사파일이 떨어질 곳 (work 레포)
: ${WORK_DIR:="/tmp/meeting-recorder-segments"}   # 회전 중 임시 세그먼트 (전사 후 정리)
