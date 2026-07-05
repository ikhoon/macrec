#!/bin/zsh
# install.sh — build macrec, STABLE-sign it (TCC 권한이 rebuild 후에도 유지),
# install to /Applications (Finder/Launchpad 노출), load the LaunchAgent.
# 산출물(회의록·오디오)은 config의 OUTPUT_ROOT(work 노트 DB)로 간다.
set -e
HERE="${0:A:h}"
[[ -f "$HERE/config.sh" ]] || cp "$HERE/config.sh.example" "$HERE/config.sh"   # first run: seed per-machine config
source "$HERE/config.sh"

LABEL="com.ikhoon.macrec"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
STAGE="$HERE/MeetingCapture.app"                     # build staging (gitignored)
STAGE_BIN="$STAGE/Contents/MacOS/macrec"

echo "▸ 안정적 코드서명 인증서 확인/생성…"
"$HERE/make-signing-cert.sh"

echo "▸ generating app icon (if missing)…"
if [[ ! -f "$HERE/AppIcon.icns" ]]; then
  rm -rf "$HERE/AppIcon.iconset"; mkdir -p "$HERE/AppIcon.iconset"
  swift "$HERE/make-icon.swift" "$HERE/AppIcon.iconset" && iconutil -c icns "$HERE/AppIcon.iconset" -o "$HERE/AppIcon.icns"
  rm -rf "$HERE/AppIcon.iconset"
fi

echo "▸ building macrec…"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
SPEEX_PREFIX="$(brew --prefix speexdsp 2>/dev/null || echo /opt/homebrew/opt/speexdsp)"
[[ -f "$SPEEX_PREFIX/lib/libspeexdsp.a" ]] || { echo "❌ speexdsp 미설치 — 에코 캔슬러(AEC) 정적 링크에 필요합니다:  brew install speexdsp"; exit 1; }
swiftc -swift-version 5 -parse-as-library -O \
  -framework AVFoundation -framework CoreMedia -framework CoreAudio \
  -framework CoreGraphics -framework AppKit -framework EventKit -framework ServiceManagement -framework Speech -framework Translation \
  -import-objc-header "$HERE/speex-bridge.h" -I "$SPEEX_PREFIX/include" "$SPEEX_PREFIX/lib/libspeexdsp.a" \
  "$HERE/macrec.swift" -o "$STAGE_BIN"

echo "▸ writing Info.plist + icon…"
VERSION=$(grep -E '^let macrecVersion = ' "$HERE/macrec.swift" | sed -E 's/.*"([0-9][0-9.]*)".*/\1/')
[[ -n "$VERSION" ]] || { echo "❌ macrecVersion 파싱 실패"; exit 1; }
[[ -f "$HERE/AppIcon.icns" ]] && cp "$HERE/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
cat > "$STAGE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>macrec</string>
  <key>CFBundleDisplayName</key><string>macrec</string>
  <key>CFBundleExecutable</key><string>macrec</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSMicrophoneUsageDescription</key><string>Records meeting audio (your mic + system audio) for local transcription.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Records other participants' audio (the system audio mix) for local transcription.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Transcribes meeting audio on-device for real-time captions.</string>
  <key>NSCalendarsUsageDescription</key><string>Reads current calendar events to title transcripts with the meeting name.</string>
</dict>
</plist>
EOF

echo "▸ 서명 (staging)…"
codesign -f -s "$SIGN_ID" --identifier "$BUNDLE_ID" "$STAGE_BIN"
codesign -f -s "$SIGN_ID" --identifier "$BUNDLE_ID" "$STAGE"

echo "▸ installing → $INSTALL_APP …"
rm -rf /Applications/MeetingRecorder.app /Applications/Amanu.app 2>/dev/null   # remove pre-rename apps
# ATOMIC swap: fully build + sign + verify the bundle NEXT TO the live one (same volume), then two
# renames. The old rm→cp→codesign flow left /Applications WITHOUT macrec.app for several seconds —
# any LaunchServices touch in that window (menu click, notification tap) popped a bogus
# "macrec needs to be downloaded" dialog.
NEW_APP="/Applications/.macrec-staging.app"
OLD_APP="/Applications/.macrec-old.app"
rm -rf "$NEW_APP" "$OLD_APP"
cp -R "$STAGE" "$NEW_APP"
# nested binaries first, bundle last — the bundle seal records their hashes, so this order is what
# makes `codesign -v` come out clean
codesign -f -s "$SIGN_ID" --identifier "$BUNDLE_ID" "$NEW_APP/Contents/MacOS/meeting-capture"
codesign -f -s "$SIGN_ID" --identifier "$BUNDLE_ID" "$NEW_APP/Contents/MacOS/macrec"
codesign -f -s "$SIGN_ID" --identifier "$BUNDLE_ID" "$NEW_APP"
if ! codesign -v "$NEW_APP" 2>/dev/null; then
  rm -rf "$NEW_APP"
  echo "❌ 서명 검증 실패 — 기존 설치 유지, 중단."; exit 1
fi
DR=$(codesign -d -r- "$NEW_APP" 2>&1)
echo "  DR: ${DR##*designated => }"
if print -r -- "$DR" | grep -q "cdhash"; then
  rm -rf "$NEW_APP"
  echo "❌ DR이 여전히 cdhash 기반 — cert 서명 실패. 기존 설치 유지, 중단."; exit 1
fi
[ -d "$INSTALL_APP" ] && mv "$INSTALL_APP" "$OLD_APP"
mv "$NEW_APP" "$INSTALL_APP"
rm -rf "$OLD_APP"
echo "  ✅ cert 기반 DR — 이후 rebuild는 권한 유지됨 (원자적 교체)"
# register with LaunchServices so Finder/Launchpad pick up the icon + name
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$INSTALL_APP" 2>/dev/null || true

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
    <key>MR_CALENDAR_TITLES</key><string>true</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <!-- relaunch only on a crash (non-zero exit); a deliberate Quit from the menu stays quit -->
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>$LOGFILE</string>
  <key>StandardErrorPath</key><string>$LOGFILE</string>
</dict>
</plist>
EOF

echo "▸ (re)loading agent…"
# migrate off the pre-macrec agent label (com.ikhoon.meeting-recorder), if present
launchctl bootout "$DOMAIN/com.ikhoon.meeting-recorder" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.ikhoon.meeting-recorder.plist"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout is async — wait until the old job is fully gone, else bootstrap races → EIO(5).
for i in {1..12}; do launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null \
  || { sleep 2; launchctl bootstrap "$DOMAIN" "$PLIST"; }

echo
echo "✅ installed → $INSTALL_APP  (Finder/Launchpad에 'macrec'로 노출, 클릭하면 트레이 메뉴)"
echo "   연속 녹음(${SEGMENT_SECONDS}s 회전) → 발화 있는 시간만 전사 (화자: 나/상대)."
echo "   전사 출력: $TRANSCRIPTS_DIR"
echo
echo "👉 권한 (최초 실행 시 인라인 팝업으로 요청됨):"
echo "   • System Audio Recording Only + Microphone → 'macrec' 허용"
echo "   • Calendar → 'macrec' 허용 (일정 제목으로 transcript 제목 붙이기)"
echo "   허용 뒤 재시작:   launchctl kickstart -k $DOMAIN/$LABEL"
echo
echo "📋 Live log:  tail -f \"$LOGFILE\""
