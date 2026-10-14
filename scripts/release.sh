#!/usr/bin/env bash
# Builds a Release Veya.app and wraps it in build/release/Veya-<version>.dmg.
#
# Usage: scripts/release.sh <version>      e.g. 1.2.0 or 1.2.0-beta.1
#
#   SIGNING_IDENTITY   name of the project's self-signed code signing certificate
#                      (scripts/make-signing-certificate.sh); unset signs ad hoc,
#                      which is the build-from-source path (docs/release.md)
#   SIGNING_KEYCHAIN   keychain holding it, if not on the search list
#
# Releases are not notarized (no paid Apple account), so macOS asks users to
# approve the app once. A stable identity, unlike ad hoc, keeps the Keychain
# sign-in and permissions across updates, since they are tied to the signature.
#
# The build number is the commit count, so every tag gets a higher one than the
# last (Sparkle compares it) and rebuilding a commit reproduces it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    echo "usage: scripts/release.sh <major.minor.patch[-prerelease]>, got '$VERSION'" >&2
    exit 64
fi
BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/Veya.xcarchive"
APP="$OUT/Veya.app"
DMG="$OUT/Veya-$VERSION.dmg"
IDENTITY="${SIGNING_IDENTITY:-}"

rm -rf "$OUT"
mkdir -p "$OUT"

"$ROOT/scripts/build-xcframework.sh" release

xcodebuild archive \
    -project "$ROOT/Veya.xcodeproj" \
    -scheme Veya \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM=
ditto "$ARCHIVE/Products/Applications/Veya.app" "$APP"

if [[ -n "$IDENTITY" ]]; then
    # A release without the whole key could never verify, and so never install, an update.
    # An Ed25519 public key is 44 base64 characters; xcconfig cuts a value at "//".
    ed_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
    if [[ ${#ed_key} -ne 44 ]]; then
        echo "error: SPARKLE_PUBLIC_ED_KEY in Config/Shared.xcconfig is missing or truncated (write // as /\$()/)" >&2
        exit 1
    fi

    keychain=()
    [[ -n "${SIGNING_KEYCHAIN:-}" ]] && keychain=(--keychain "$SIGNING_KEYCHAIN")
    sign() { codesign --force --sign "$IDENTITY" "${keychain[@]}" --options runtime "$@"; }
    # Inside out, as Sparkle documents; entitlements kept where the archive set them.
    sparkle="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    sign "$sparkle/XPCServices/Installer.xpc"
    sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
    sign "$sparkle/Autoupdate"
    sign "$sparkle/Updater.app"
    sign "$APP/Contents/Frameworks/Sparkle.framework"
    # Library validation wants a matching Apple Team ID, which a self-signed certificate
    # lacks, so the app could not load Sparkle.framework. The sandbox still bounds what loads.
    codesign -d --entitlements - --xml "$APP" > "$OUT/entitlements.plist"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$OUT/entitlements.plist"
    sign --entitlements "$OUT/entitlements.plist" "$APP"
    codesign --verify --deep --strict "$APP"
fi

mkdir "$OUT/dmg"
ditto "$APP" "$OUT/dmg/Veya.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname Veya -srcfolder "$OUT/dmg" -fs HFS+ -format UDZO -ov "$DMG"

echo "$DMG"
