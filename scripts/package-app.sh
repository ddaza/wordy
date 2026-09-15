#!/bin/sh
# Build a compressed UDZO disk image for a Release Wordy.app.
#
# The image is ad-hoc signed; it is not notarized and is not a public
# distribution candidate. Milestone 4 still owns Developer ID signing,
# notarization, and Sparkle.
#
# Usage: scripts/package-app.sh <Wordy.app> <output-dir> <universal|arm64|x86_64>
set -eu

APP="${1:-}"
OUT_DIR="${2:-}"
VARIANT="${3:-}"

case "$VARIANT" in
    universal) VOLUME_SUFFIX="" ;;
    arm64) VOLUME_SUFFIX=" arm64" ;;
    x86_64) VOLUME_SUFFIX=" Intel" ;;
    *)
        echo "Usage: scripts/package-app.sh <Wordy.app> <output-dir> <universal|arm64|x86_64>" >&2
        exit 1
        ;;
esac

if [ ! -d "$APP" ]; then
    echo "Release app not found at $APP" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ -z "$VERSION" ] || [ "$VERSION" = '$(MARKETING_VERSION)' ]; then
    echo "Could not read CFBundleShortVersionString from $APP" >&2
    exit 1
fi

DMG_NAME="Wordy-${VERSION}-macos-${VARIANT}.dmg"
DMG_PATH="$OUT_DIR/$DMG_NAME"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/wordy-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$OUT_DIR"
rm -f "$DMG_PATH"
ditto "$APP" "$STAGE/Wordy.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
    -volname "Wordy ${VERSION}${VOLUME_SUFFIX}" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH" >/dev/null

printf 'Wrote %s (%s)\n' "$DMG_PATH" "$VERSION"
