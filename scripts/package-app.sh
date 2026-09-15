#!/bin/sh
# Zip the Universal Release app for a GitHub release attachment.
#
# The zip is ad-hoc signed; it is not notarized and is not a public
# distribution candidate. Milestone 4 still owns Developer ID signing,
# notarization, and Sparkle.
#
# Usage: scripts/package-app.sh [Wordy.app] [output-dir]
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/DerivedData/Build/Products/Release/Wordy.app}"
OUT_DIR="${2:-$ROOT/build/dist}"

if [ ! -d "$APP" ]; then
    echo "Release app not found at $APP. Run make verify-universal first." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ -z "$VERSION" ] || [ "$VERSION" = '$(MARKETING_VERSION)' ]; then
    echo "Could not read CFBundleShortVersionString from $APP" >&2
    exit 1
fi

ZIP_NAME="Wordy-${VERSION}-macos-universal.zip"
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/$ZIP_NAME" "$OUT_DIR/SHA256SUMS.txt"
ditto -c -k --keepParent "$APP" "$OUT_DIR/$ZIP_NAME"
(
    cd "$OUT_DIR"
    shasum -a 256 "$ZIP_NAME" >SHA256SUMS.txt
)
printf 'Wrote %s (%s)\n' "$OUT_DIR/$ZIP_NAME" "$VERSION"
cat "$OUT_DIR/SHA256SUMS.txt"
