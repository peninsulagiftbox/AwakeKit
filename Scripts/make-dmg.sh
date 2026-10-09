#!/bin/bash
# Package dist/AwakeKit.app into dist/AwakeKit.dmg.
#
# The DMG uses the classic drag-to-install layout: the app alongside a symlink
# to /Applications. Handed to a user, they drag the app into the shortcut to
# install it.
#
# Usage: Scripts/make-dmg.sh [debug|release] (default: release).
# Always rebuild the app so the image contains the requested configuration
# and current source, even when dist/AwakeKit.app already exists.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="AwakeKit"
APP="$ROOT/dist/$APP_NAME.app"
STAGING="$ROOT/dist/.dmg-staging"
VERIFY="$ROOT/dist/.dmg-verify"
DMG="$ROOT/dist/$APP_NAME.dmg"

cd "$ROOT"

bash "$ROOT/Scripts/make-app.sh" "$CONFIG"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "1.0")"

echo "==> Staging DMG contents"
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating $DMG"
rm -f "$DMG"
# hdiutil create is deprecated on macOS 26+ and can fail there ("Resource
# busy"); prefer diskutil image create when available.
if diskutil image create from \
        --format UDZO \
        --volumeName "$APP_NAME $VERSION" \
        "$STAGING" "$DMG" >/dev/null 2>&1; then
    :
else
    hdiutil create \
        -volname "$APP_NAME $VERSION" \
        -srcfolder "$STAGING" \
        -format UDZO \
        -ov "$DMG" >/dev/null
fi

rm -rf "$STAGING"

echo "==> Verifying"
mkdir -p "$VERIFY"
hdiutil attach "$DMG" -mountpoint "$VERIFY" -nobrowse -quiet
if [ ! -d "$VERIFY/$APP_NAME.app" ] || [ ! -e "$VERIFY/Applications" ]; then
    echo "    DMG verification FAILED"
    hdiutil detach "$VERIFY" -quiet || true
    exit 1
fi
codesign --verify "$VERIFY/$APP_NAME.app"
hdiutil detach "$VERIFY" -quiet
rm -rf "$VERIFY"

echo "==> Done: $DMG (volume: $APP_NAME $VERSION)"
