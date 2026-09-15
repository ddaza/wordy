#!/bin/sh
# Verify a Release Wordy.app: version, icon, signature, whisper engine, and arch.
#
# Usage: scripts/verify-app.sh <Wordy.app> <universal|arm64|x86_64> [expected-version]
set -eu

APP="${1:-}"
VARIANT="${2:-}"
EXPECTED="${3:-}"

if [ ! -d "$APP" ] || [ -z "$VARIANT" ]; then
    echo "Usage: scripts/verify-app.sh <Wordy.app> <universal|arm64|x86_64> [expected-version]" >&2
    exit 1
fi

EXE="$APP/Contents/MacOS/Wordy"
WORKER="$APP/Contents/XPCServices/WordyTranscriptionService.xpc/Contents/MacOS/WordyTranscriptionService"
PLIST="$APP/Contents/Info.plist"

for path in "$EXE" "$WORKER" "$PLIST"; do
    if [ ! -e "$path" ]; then
        echo "missing $path" >&2
        exit 1
    fi
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
if [ -z "$VERSION" ] || [ "$VERSION" = '$(MARKETING_VERSION)' ]; then
    echo "CFBundleShortVersionString is unset in $PLIST" >&2
    exit 1
fi
if [ -n "$EXPECTED" ] && [ "$VERSION" != "$EXPECTED" ]; then
    echo "app version $VERSION does not match $EXPECTED" >&2
    exit 1
fi

ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$PLIST" 2>/dev/null || true)"
if [ "$ICON_NAME" != AppIcon ]; then
    echo "CFBundleIconName is '${ICON_NAME:-empty}', expected AppIcon" >&2
    exit 1
fi
if [ ! -f "$APP/Contents/Resources/AppIcon.icns" ]; then
    echo "AppIcon.icns is missing from $APP" >&2
    exit 1
fi

check_arch() {
    binary="$1"
    case "$VARIANT" in
        universal)
            lipo "$binary" -verify_arch arm64 x86_64
            ;;
        arm64)
            lipo "$binary" -verify_arch arm64
            if lipo "$binary" -verify_arch x86_64 2>/dev/null; then
                echo "$binary unexpectedly contains x86_64" >&2
                exit 1
            fi
            ;;
        x86_64)
            lipo "$binary" -verify_arch x86_64
            if lipo "$binary" -verify_arch arm64 2>/dev/null; then
                echo "$binary unexpectedly contains arm64" >&2
                exit 1
            fi
            ;;
        *)
            echo "unknown variant: $VARIANT" >&2
            exit 1
            ;;
    esac
}

check_arch "$EXE"
check_arch "$WORKER"
codesign --verify --deep --strict --verbose=2 "$APP"
if ! nm "$WORKER" | grep -q ' T _whisper_full$'; then
    echo "worker does not contain the whisper engine" >&2
    exit 1
fi

printf 'Verified %s %s (v%s)\n' "$(basename "$APP" .app)" "$VARIANT" "$VERSION"
