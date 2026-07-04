#!/bin/zsh
# package.sh — build a SELF-CONTAINED, self-signed macrec.app for DISTRIBUTION.
#
# Unlike install.sh (which targets *this* machine + Homebrew whisper + LaunchAgent), this
# produces a .app others can download & run with NO Homebrew and NO pre-installed model:
#   • whisper-cli is built from source STATIC (Metal embedded, no dlopen backends) → bundled
#   • the silero VAD model (small) is bundled
#   • the large transcription model (~1.6GB) downloads on first run (App Support)
# Output: dist/macrec.zip  — unzip, drag to /Applications, launch.
set -e
HERE="${0:A:h}"
[[ -f "$HERE/config.sh" ]] || cp "$HERE/config.sh.example" "$HERE/config.sh"   # first run: seed per-machine config
source "$HERE/config.sh"

DIST="$HERE/dist"
APP="$DIST/macrec.app"
WBUILD="$HERE/.build/whisper.cpp"                  # cached whisper.cpp checkout + build
SILERO="$HOME/whisper-models/ggml-silero-v5.1.2.bin"
SILERO_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"

# ── 0) preflight: cmake + a WORKING C++ toolchain ───────────────────────────────
command -v cmake >/dev/null || { echo "❌ cmake 필요:  brew install cmake"; exit 1; }
if ! printf '#include <array>\nint main(){std::array<int,1> a; return (int)a.size();}\n' \
     | c++ -x c++ -std=c++17 - -o /tmp/_cxxcheck 2>/dev/null; then
  cat <<'MSG'
❌ C++ 툴체인이 깨져 있습니다 (libc++ 헤더 누락 — macOS 업그레이드 후 CommandLineTools 반쪽 설치).
   whisper.cpp(C++)를 빌드할 수 없습니다. 먼저 복구하세요:

       sudo rm -rf /Library/Developer/CommandLineTools
       sudo xcode-select --install      # 설치창 동의 → ~5–10분

   복구 확인:  echo '#include <array>\nint main(){}' | c++ -x c++ -std=c++17 - -o /tmp/t && echo OK
   그 다음 다시:  ./package.sh
MSG
  exit 1
fi
rm -f /tmp/_cxxcheck

# ── 1) stable signing cert (TCC 권한이 rebuild 후에도 유지) ──────────────────────
"$HERE/make-signing-cert.sh"

# ── 2) self-contained whisper-cli (static libs, Metal embedded, no backend .so) ──
WCLI="$WBUILD/build/bin/whisper-cli"
if [[ ! -x "$WCLI" || -n "$REBUILD_WHISPER" ]]; then
  echo "▸ building self-contained whisper-cli (static + Metal embed)…  (최초 1회, 수 분)"
  mkdir -p "$HERE/.build"
  [[ -d "$WBUILD/.git" ]] || git clone --depth 1 https://github.com/ggml-org/whisper.cpp "$WBUILD"
  SDK="$(xcrun --show-sdk-path)"
  cmake -S "$WBUILD" -B "$WBUILD/build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_SYSROOT="$SDK" \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BACKEND_DL=OFF \
    -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF >/dev/null
  cmake --build "$WBUILD/build" --config Release -j --target whisper-cli >/dev/null
fi
[[ -x "$WCLI" ]] || { echo "❌ whisper-cli 빌드 실패"; exit 1; }
if otool -L "$WCLI" | grep -q "/opt/homebrew"; then
  echo "❌ whisper-cli가 여전히 /opt/homebrew에 의존 (static 빌드 실패):"; otool -L "$WCLI" | grep homebrew; exit 1
fi
echo "  ✅ self-contained whisper-cli ($(du -h "$WCLI" | cut -f1)) — homebrew 의존 0"

# ── 3) silero VAD (작아서 번들) ─────────────────────────────────────────────────
if [[ ! -f "$SILERO" ]]; then
  echo "▸ fetching silero VAD…"; mkdir -p "$(dirname "$SILERO")"
  curl -fL "$SILERO_URL" -o "$SILERO"
fi

# ── 4) app icon (없으면 생성) ───────────────────────────────────────────────────
if [[ ! -f "$HERE/AppIcon.icns" ]]; then
  rm -rf "$HERE/AppIcon.iconset"; mkdir -p "$HERE/AppIcon.iconset"
  swift "$HERE/make-icon.swift" "$HERE/AppIcon.iconset" && iconutil -c icns "$HERE/AppIcon.iconset" -o "$HERE/AppIcon.icns"
  rm -rf "$HERE/AppIcon.iconset"
fi

# ── 5) build the Swift app into the .app ────────────────────────────────────────
echo "▸ building macrec…"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
SPEEX_PREFIX="$(brew --prefix speexdsp 2>/dev/null || echo /opt/homebrew/opt/speexdsp)"
swiftc -swift-version 5 -parse-as-library -O \
  -framework AVFoundation -framework CoreMedia -framework CoreAudio \
  -framework CoreGraphics -framework AppKit -framework EventKit -framework ServiceManagement -framework Speech -framework Translation \
  -import-objc-header "$HERE/speex-bridge.h" -I "$SPEEX_PREFIX/include" "$SPEEX_PREFIX/lib/libspeexdsp.a" \
  "$HERE/macrec.swift" -o "$APP/Contents/MacOS/macrec"

# ── 6) bundle whisper-cli + VAD + icon ──────────────────────────────────────────
cp "$WCLI"    "$APP/Contents/Helpers/whisper-cli"
cp "$SILERO"  "$APP/Contents/Resources/ggml-silero-v5.1.2.bin"
cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# ── 7) Info.plist (no MR_* env — app auto-resolves bundled cli/VAD + App Support model) ──
VERSION=$(grep -E '^let macrecVersion = ' "$HERE/macrec.swift" | sed -E 's/.*"([0-9][0-9.]*)".*/\1/')
[[ -n "$VERSION" ]] || { echo "❌ macrecVersion 파싱 실패"; exit 1; }
cat > "$APP/Contents/Info.plist" <<EOF
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

# ── 8) sign inside-out (nested code first, then seal the bundle) ─────────────────
echo "▸ signing (self-signed cert: $SIGN_ID)…"
codesign -f -s "$SIGN_ID" "$APP/Contents/Helpers/whisper-cli"
codesign -f -s "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP/Contents/MacOS/macrec"
codesign -f -s "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP" && echo "  ✅ signature valid (nested whisper-cli sealed)"
DR=$(codesign -d -r- "$APP" 2>&1)
if print -r -- "$DR" | grep -q "cdhash"; then
  echo "❌ DR이 cdhash 기반 — cert 서명 실패. 중단."; exit 1
fi
echo "  ✅ cert 기반 DR — 유저가 권한 1회 허용하면 업데이트 후에도 유지"

# ── 9) zip for distribution (preserves signature + structure) ───────────────────
echo "▸ zipping…"
( cd "$DIST" && rm -f macrec.zip && ditto -c -k --sequesterRsrc --keepParent "macrec.app" "macrec.zip" )

echo
echo "✅ 배포물: $DIST/macrec.zip  ($(du -h "$DIST/macrec.zip" | cut -f1))"
echo "   포함: 앱 + self-contained whisper-cli + silero VAD.  (큰 모델은 첫 실행에 다운로드)"
echo
echo "👉 유저 설치:"
echo "   1) zip 풀고 macrec.app 을 /Applications 로 드래그"
echo "   2) 첫 실행: 차단되면 System Settings → Privacy & Security → 'Open Anyway' (1회)"
echo "   3) 권한 허용 (인라인 팝업): System Audio Recording Only · Microphone · Calendar"
echo "   4) 트레이 메뉴에 '⤓ Downloading model… %' → 완료되면 자동 전사 시작"
