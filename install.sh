#!/bin/zsh
# install.sh — build meeting-capture, STABLE-sign it (TCC 권한이 rebuild 후에도 유지),
# install the LaunchAgent. 산출물(회의록·오디오)은 config의 OUTPUT_ROOT(work 노트 DB)로 간다.
set -e
HERE="${0:A:h}"
source "$HERE/config.sh"

LABEL="com.ikhoon.meeting-recorder"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
APP="$HERE/MeetingCapture.app"

echo "▸ 안정적 코드서명 인증서 확인/생성…"
"$HERE/make-signing-cert.sh"

echo "▸ building meeting-capture…"
mkdir -p "$APP/Contents/MacOS"
if [[ ! -x "$CAPTURE" || "$HERE/MeetingCapture.swift" -nt "$CAPTURE" ]]; then
  swiftc -swift-version 5 -parse-as-library -O \
    -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia -framework CoreAudio -framework CoreGraphics \
    "$HERE/MeetingCapture.swift" -o "$CAPTURE"
fi

echo "▸ writing Info.plist (고정 CFBundleIdentifier=$BUNDLE_ID)…"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>MeetingCapture</string>
  <key>CFBundleDisplayName</key><string>Meeting Capture</string>
  <key>CFBundleExecutable</key><string>meeting-capture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSMicrophoneUsageDescription</key><string>Records meeting audio (your mic + system audio) for local transcription.</string>
</dict>
</plist>
EOF

echo "▸ 안정적 인증서 '$SIGN_ID'로 서명 (DR이 cdhash가 아닌 cert 기반 → rebuild해도 TCC 권한 유지)…"
codesign -f -s "$SIGN_ID" --identifier "$BUNDLE_ID" "$CAPTURE"   # 내부 Mach-O 먼저
codesign -f -s "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"       # 번들 전체
DR=$(codesign -d -r- "$APP" 2>&1)
echo "  DR: ${DR##*designated => }"
if print -r -- "$DR" | grep -q "cdhash"; then
  echo "❌ DR이 여전히 cdhash 기반 — cert 서명 실패. 'security find-identity -p codesigning'에 $SIGN_ID 있는지 확인. 중단."
  exit 1
fi
echo "  ✅ cert 기반 DR — 이후 rebuild는 권한 유지됨"

chmod +x "$HERE"/*.sh

mkdir -p "$TRANSCRIPTS_DIR"

echo "▸ writing LaunchAgent → $PLIST (앱 모드: 메뉴바 트레이 + 연속 엔진)"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$CAPTURE</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>MR_SEGMENT_SECONDS</key><string>$SEGMENT_SECONDS</string>
    <key>MR_VOICE_MIN_SECONDS</key><string>$VOICE_MIN_SECONDS</string>
    <key>MR_TRANSCRIPTS_DIR</key><string>$TRANSCRIPTS_DIR</string>
    <key>MR_WORK_DIR</key><string>$WORK_DIR</string>
    <key>MR_WHISPER_CLI</key><string>$WHISPER_CLI</string>
    <key>MR_WHISPER_GGML</key><string>$WHISPER_GGML</string>
    <key>MR_VAD_MODEL</key><string>$VAD_MODEL</string>
    <key>MR_WHISPER_LANG</key><string>$WHISPER_LANG</string>
    <key>MR_EXCLUDE_APPS</key><string>$EXCLUDE_APPS</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOGFILE</string>
  <key>StandardErrorPath</key><string>$LOGFILE</string>
</dict>
</plist>
EOF

echo "▸ (re)loading agent…"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout is async — wait until the old job is fully gone, else bootstrap races → EIO(5).
for i in {1..12}; do launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null \
  || { sleep 2; launchctl bootstrap "$DOMAIN" "$PLIST"; }

echo
echo "✅ installed → 앱: $APP"
echo "   메뉴바에 🎙 트레이 아이콘이 뜨고, 연속 녹음(${SEGMENT_SECONDS}s 회전) → 발화 있는 시간만 전사."
echo "   전사 출력: $TRANSCRIPTS_DIR"
echo
echo "👉 권한(처음 1회만): System Settings → Privacy & Security →"
echo "     • Screen & System Audio Recording → enable \"meeting-capture\""
echo "     • Microphone                      → enable \"meeting-capture\""
echo "   (목록에 없으면 $HERE/register-permissions.sh 실행 후 다시 확인)"
echo "   허용 뒤 재시작:   launchctl kickstart -k $DOMAIN/$LABEL"
echo "   cert 서명이라 이후 재빌드(./install.sh)해도 권한은 유지됩니다."
echo
echo "📋 Live log:  tail -f \"$LOGFILE\"    ·    트레이 메뉴에서 일시정지/종료/transcripts 열기"
