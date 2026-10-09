#!/usr/bin/env bash
# Build CallRec and wrap the SwiftPM executable into a menu-bar (LSUIElement) .app.
# Usage: ./scripts/bundle.sh [debug|release] [--install]
set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="CallRec"
BUNDLE_ID="app.callrec.CallRec"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/$APP_NAME.app"

# CALLREC_UNIVERSAL=1 builds arm64 + x86_64 (for release downloads)
ARCHS=()
[ -n "${CALLREC_UNIVERSAL:-}" ] && ARCHS=(--arch arm64 --arch x86_64)
echo "→ swift build -c $CONFIG ${ARCHS[*]:-}"
swift build -c "$CONFIG" --package-path "$ROOT" ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/$APP_NAME"

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT Licensed</string>
  <key>NSMicrophoneUsageDescription</key><string>CallRec records your side of the call.</string>
  <key>NSAudioCaptureUsageDescription</key><string>CallRec records the other side of the call (system audio).</string>
</dict>
</plist>
PLIST

# Sign with a local Apple identity so macOS permissions survive rebuilds.
# CALLREC_SIGN_IDENTITY forces a specific one; otherwise the first Apple Development /
# Developer ID identity is used, falling back to ad-hoc.
if [ -n "${CALLREC_SIGN_IDENTITY:-}" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep "$CALLREC_SIGN_IDENTITY" || true)"
else
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -E 'Apple Development|Developer ID Application' || true)"
fi
IDENTITY="$(echo "$IDENTITY" | head -1 | awk '{print $2}')"
if [ -n "$IDENTITY" ]; then
  echo "→ signing with $IDENTITY"
  codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
else
  echo "→ no developer identity found, ad-hoc signing"
  codesign --force --sign - "$APP"
fi

if [ "${2:-}" = "--install" ]; then
  echo "→ installing to /Applications"
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
fi
echo "✓ $APP"
