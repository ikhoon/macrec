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
command -v cmake >/dev/null || { echo "❌ cmake required:  brew install cmake"; exit 1; }
if ! printf '#include <array>\nint main(){std::array<int,1> a; return (int)a.size();}\n' \
     | c++ -x c++ -std=c++17 - -o /tmp/_cxxcheck 2>/dev/null; then
  cat <<'MSG'
❌ The C++ toolchain is broken (libc++ headers missing — CommandLineTools half-installed after a macOS upgrade).
   whisper.cpp (C++) cannot be built. Repair it first:

       sudo rm -rf /Library/Developer/CommandLineTools
       sudo xcode-select --install      # accept the install dialog → ~5–10 min

   Verify the repair:  echo '#include <array>\nint main(){}' | c++ -x c++ -std=c++17 - -o /tmp/t && echo OK
   Then run again:  ./package.sh
MSG
  exit 1
fi
rm -f /tmp/_cxxcheck

# ── 1) stable signing cert (TCC grants survive rebuilds) ────────────────────────
"$HERE/make-signing-cert.sh"

# ── 2) self-contained whisper-cli (static libs, Metal embedded, no backend .so) ──
WCLI="$WBUILD/build/bin/whisper-cli"
if [[ ! -x "$WCLI" || -n "$REBUILD_WHISPER" ]]; then
  echo "▸ building self-contained whisper-cli (static + Metal embed)…  (first time only, takes minutes)"
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
[[ -x "$WCLI" ]] || { echo "❌ whisper-cli build failed"; exit 1; }
if otool -L "$WCLI" | grep -q "/opt/homebrew"; then
  echo "❌ whisper-cli still depends on /opt/homebrew (static build failed):"; otool -L "$WCLI" | grep homebrew; exit 1
fi
echo "  ✅ self-contained whisper-cli ($(du -h "$WCLI" | cut -f1)) — zero homebrew deps"

# ── 3) silero VAD (small, so bundled) ───────────────────────────────────────────
if [[ ! -f "$SILERO" ]]; then
  echo "▸ fetching silero VAD…"; mkdir -p "$(dirname "$SILERO")"
  curl -fL "$SILERO_URL" -o "$SILERO"
fi

# ── 4) app icon (generated if missing) ──────────────────────────────────────────
if [[ ! -f "$HERE/AppIcon.icns" ]]; then
  rm -rf "$HERE/AppIcon.iconset"; mkdir -p "$HERE/AppIcon.iconset"
  swift "$HERE/make-icon.swift" "$HERE/AppIcon.iconset" && iconutil -c icns "$HERE/AppIcon.iconset" -o "$HERE/AppIcon.icns"
  rm -rf "$HERE/AppIcon.iconset"
fi

# ── 5) build the Swift app into the .app ────────────────────────────────────────
echo "▸ building macrec…"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
SPEEX_PREFIX="$(brew --prefix speexdsp 2>/dev/null || echo /opt/homebrew/opt/speexdsp)"
[[ -f "$SPEEX_PREFIX/lib/libspeexdsp.a" ]] || { echo "❌ speexdsp not installed — needed to statically link the echo canceller (AEC):  brew install speexdsp"; exit 1; }
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
[[ -n "$VERSION" ]] || { echo "❌ failed to parse macrecVersion"; exit 1; }
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
  echo "❌ DR is cdhash-based — cert signing failed. Aborting."; exit 1
fi
echo "  ✅ cert-based DR — permissions the user grants once persist across updates"

# ── 9) zip for distribution (preserves signature + structure) ───────────────────
echo "▸ zipping…"
( cd "$DIST" && rm -f macrec.zip && ditto -c -k --sequesterRsrc --keepParent "macrec.app" "macrec.zip" )

echo
echo "✅ distributable: $DIST/macrec.zip  ($(du -h "$DIST/macrec.zip" | cut -f1))"
echo "   Includes: app + self-contained whisper-cli + silero VAD.  (the large model downloads on first run)"
echo
echo "👉 User install:"
echo "   1) unzip and drag macrec.app to /Applications"
echo "   2) first launch: if blocked, System Settings → Privacy & Security → 'Open Anyway' (once)"
echo "   3) grant permissions (inline popups): System Audio Recording Only · Microphone · Calendar"
echo "   4) tray menu shows '⤓ Downloading model… %' → transcription starts automatically when done"
