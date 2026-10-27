#!/bin/bash
# Publish a release and push the Sparkle appcast so installed apps update
# themselves.
#
# Usage: Scripts/release.sh <version> [notes]
#   e.g. Scripts/release.sh 1.0.3 "新增自动更新：应用每小时检查并提示安装新版本"
#
# Steps:
#   1. Bump CFBundleShortVersionString / CFBundleVersion in Scripts/Info.plist
#      (Sparkle compares the build number, so it must strictly increase)
#   2. Build dist/AwakeKit-<version>.dmg and EdDSA-sign it
#   3. Commit "Release <version>", tag v<version>, push main + tag
#   4. Create the GitHub release and upload the DMG
#   5. Insert an <item> into appcast.xml, commit and push (feed goes live)
#
# Requirements:
#   - clean working tree, on main
#   - gh authenticated (gh auth status)
#   - Sparkle EdDSA key in the login Keychain (bin/generate_keys, run once;
#     scripts/make-app.sh pulls the framework via 'swift build')
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="peninsulagiftbox/AwakeKit"
APP_NAME="AwakeKit"
PLIST="$ROOT/Scripts/Info.plist"
SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"

VERSION="${1:?Usage: Scripts/release.sh <version> [notes]}"
NOTES="${2:-AwakeKit $VERSION}"
TAG="v$VERSION"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must look like 1.2.3, got: $VERSION" >&2
    exit 1
fi
if [ "$(git -C "$ROOT" branch --show-current)" != "main" ]; then
    echo "Releases are cut from main." >&2
    exit 1
fi
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "Working tree is not clean; commit or stash first." >&2
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "gh is not authenticated; run 'gh auth login'." >&2
    exit 1
fi
if [ ! -x "$SIGN_UPDATE" ]; then
    echo "sign_update not found at $SIGN_UPDATE; run 'swift build' once." >&2
    exit 1
fi
if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "Tag $TAG already exists." >&2
    exit 1
fi

cd "$ROOT"

echo "==> Bumping version to $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD + 1))" "$PLIST"

echo "==> Building DMG"
bash "$ROOT/Scripts/make-dmg.sh" release
DMG="$ROOT/dist/$APP_NAME-$VERSION.dmg"
if [ ! -f "$DMG" ]; then
    echo "Expected $DMG missing after build." >&2
    exit 1
fi

echo "==> EdDSA-signing the DMG"
SIGN_OUT="$("$SIGN_UPDATE" "$DMG")"
EDSIG="$(sed -E 's/.*edSignature="([^"]+)".*/\1/' <<<"$SIGN_OUT")"
EDLEN="$(sed -E 's/.*length="([^"]+)".*/\1/' <<<"$SIGN_OUT")"
if [ -z "$EDSIG" ] || [ -z "$EDLEN" ]; then
    echo "Could not parse sign_update output: $SIGN_OUT" >&2
    exit 1
fi

echo "==> Committing and pushing $TAG"
git add "$PLIST"
git commit -m "Release $VERSION"
git tag "$TAG"
git push origin main "$TAG"

echo "==> Creating GitHub release $TAG"
gh release create "$TAG" "$DMG" \
    --repo "$REPO" \
    --title "AwakeKit $VERSION" \
    --notes "$NOTES" \
    --latest

echo "==> Updating appcast"
DMG_URL="https://github.com/$REPO/releases/download/$TAG/$APP_NAME-$VERSION.dmg"
APP_PLIST="$ROOT/dist/$APP_NAME.app/Contents/Info.plist"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PLIST")"
MIN_SYS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_PLIST")"
python3 "$ROOT/Scripts/update-appcast.py" \
    "$VERSION" "$BUILD" "$EDSIG" "$EDLEN" "$NOTES" "$DMG_URL" "$MIN_SYS"
git add appcast.xml
git commit -m "Update appcast for $VERSION"
git push origin main

echo "==> Released $VERSION — installed apps will pick it up within an hour."
