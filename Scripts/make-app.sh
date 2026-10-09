#!/bin/bash
# Assemble AwakeKit.app from the SwiftPM build.
#
# A real bundle matters beyond packaging: macOS decides which design language and
# window materials an app gets partly from its bundle identity. Running the bare
# Mach-O out of .build/ leaves the process without an app identity, and the
# system then renders legacy materials instead of Liquid Glass.
#
# Usage: Scripts/make-app.sh [debug|release]   (default: release)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
case "$CONFIG" in
    debug|release) ;;
    *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;;
esac
APP_NAME="AwakeKit"
APP="$ROOT/dist/$APP_NAME.app"

cd "$ROOT"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# SwiftPM records the deployment target as the SDK version. Correct only the
# packaged executable so modern window materials work without forcing the
# app's deployment target onto the macOS 14+ testing framework.
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
EXECUTABLE="$APP/Contents/MacOS/$APP_NAME"
if codesign -d "$EXECUTABLE" >/dev/null 2>&1; then
    codesign --remove-signature "$EXECUTABLE"
fi
xcrun vtool -set-build-version macos "$MIN_OS" "$SDK_VERSION" -replace \
    -output "$EXECUTABLE.sdk" "$EXECUTABLE"
mv "$EXECUTABLE.sdk" "$EXECUTABLE"
chmod +x "$EXECUTABLE"

# Ad-hoc identity ("-", the default) changes on every rebuild, so macOS treats
# each new build as a modified app and resets SMAppService login-item approval.
# Export CODESIGN_IDENTITY with a self-signed Keychain certificate name for a
# stable identity across rebuilds.
IDENTITY="${CODESIGN_IDENTITY:--}"
echo "==> Signing ($IDENTITY)"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify "$APP"

echo "==> Done: $APP"
