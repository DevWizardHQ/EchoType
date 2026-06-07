#!/bin/bash
# Builds EchoType.app bundle from the SwiftPM executable.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_DIR="dist/EchoType.app"

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG"

BINARY=".build/$CONFIG/EchoType"

echo "▸ Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/EchoType"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png "$APP_DIR/Contents/Resources/MenuBarIcon.png"

# Prefer a stable signing identity so macOS TCC permissions (Accessibility,
# Microphone) survive rebuilds. Falls back to the HoldTalk dev cert if present,
# then ad-hoc.
IDENTITY="${ECHOTYPE_SIGN_IDENTITY:-EchoType Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "▸ Codesigning with identity: $IDENTITY"
    codesign --force --sign "$IDENTITY" --identifier com.devwizardhq.echotype "$APP_DIR"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "HoldTalk Dev"; then
    echo "▸ Codesigning with identity: HoldTalk Dev (shared dev cert)"
    codesign --force --sign "HoldTalk Dev" --identifier com.devwizardhq.echotype "$APP_DIR"
else
    echo "▸ Codesigning (ad-hoc — TCC permissions will reset on each rebuild)"
    codesign --force --sign - --identifier com.devwizardhq.echotype "$APP_DIR"
fi

echo "✓ Built $APP_DIR"
echo "  Run with: open $APP_DIR"
