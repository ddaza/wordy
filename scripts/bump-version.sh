#!/bin/sh
# Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in Config/Version.xcconfig.
#
# Usage: scripts/bump-version.sh patch|minor|major
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/Config/Version.xcconfig"
KIND="${1:-}"

case "$KIND" in
    major | minor | patch) ;;
    *)
        echo "Usage: make version-bump patch|minor|major" >&2
        exit 1
        ;;
esac

if [ ! -f "$FILE" ]; then
    echo "missing $FILE" >&2
    exit 1
fi

VERSION="$(awk '/^MARKETING_VERSION/{print $3}' "$FILE")"
BUILD="$(awk '/^CURRENT_PROJECT_VERSION/{print $3}' "$FILE")"

MAJOR="${VERSION%%.*}"
REST="${VERSION#*.}"
MINOR="${REST%%.*}"
PATCH="${REST#*.}"

for part in "$MAJOR" "$MINOR" "$PATCH" "$BUILD"; do
    case "$part" in
        '' | *[!0-9]*)
            echo "Could not read a major.minor.patch version from $FILE" >&2
            exit 1
            ;;
    esac
done

case "$PATCH" in
    *.*)
        echo "MARKETING_VERSION must be major.minor.patch" >&2
        exit 1
        ;;
esac

case "$KIND" in
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
    patch)
        PATCH=$((PATCH + 1))
        ;;
esac

BUILD=$((BUILD + 1))
NEW="$MAJOR.$MINOR.$PATCH"

{
    printf '%s\n' \
        '// Single source for CFBundleShortVersionString and CFBundleVersion.' \
        '// Git tags and disk image names are v$(MARKETING_VERSION). Bump both values' \
        '// together before `make package`.' \
        "MARKETING_VERSION = $NEW" \
        "CURRENT_PROJECT_VERSION = $BUILD"
} >"$FILE"

printf 'Bumped %s → %s (build %s)\n' "$VERSION" "$NEW" "$BUILD"
