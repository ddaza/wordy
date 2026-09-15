#!/bin/sh
# Secondary check of make package disk images, then publish with gh.
#
# Usage: scripts/push-release.sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(awk '/^MARKETING_VERSION/{print $3}' Config/Version.xcconfig)"
DIST="${WORDY_DIST:-$ROOT/build/dist}"
TAG="v${VERSION}"
UNIVERSAL="$DIST/Wordy-${VERSION}-macos-universal.dmg"
ARM64="$DIST/Wordy-${VERSION}-macos-arm64.dmg"
X86="$DIST/Wordy-${VERSION}-macos-x86_64.dmg"
NOTES="$DIST/RELEASE_NOTES.md"

if [ -z "$VERSION" ]; then
    echo "Could not read MARKETING_VERSION from Config/Version.xcconfig" >&2
    exit 1
fi

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "Tracked files are dirty; commit or stash before make release." >&2
    git status --porcelain --untracked-files=no >&2
    exit 1
fi

command -v gh >/dev/null || {
    echo "gh is required (GitHub CLI)." >&2
    exit 1
}

for dmg in "$UNIVERSAL" "$ARM64" "$X86"; do
    if [ ! -f "$dmg" ]; then
        echo "missing $dmg; run make package first." >&2
        exit 1
    fi
done
if [ ! -f "$NOTES" ] || [ ! -f "$DIST/SHA256SUMS.txt" ]; then
    echo "missing release notes or checksums in $DIST; run make package first." >&2
    exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "git tag $TAG already exists locally." >&2
    exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "GitHub release $TAG already exists." >&2
    exit 1
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mounts=""

detach_all() {
    for mount in $mounts; do
        hdiutil detach "$mount" -quiet 2>/dev/null || true
    done
    rm -rf "$scratch"
}
trap detach_all EXIT

verify_dmg() {
    dmg="$1"
    variant="$2"
    mount="$scratch/$variant"
    mkdir -p "$mount"
    hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$dmg" >/dev/null
    mounts="$mounts $mount"
    sh "$ROOT/scripts/verify-app.sh" "$mount/Wordy.app" "$variant" "$VERSION"
    hdiutil detach "$mount" >/dev/null
    mounts=$(echo "$mounts" | sed "s| $mount||")
}

verify_dmg "$UNIVERSAL" universal
verify_dmg "$ARM64" arm64
verify_dmg "$X86" x86_64

printf 'Checks passed for %s. Publishing GitHub release.\n' "$TAG"

git push
prerelease=""
case "$VERSION" in
    0.*) prerelease="--prerelease" ;;
esac
# shellcheck disable=SC2086
gh release create "$TAG" $prerelease \
    --title "Wordy $VERSION" \
    --notes-file "$NOTES" \
    "$UNIVERSAL" "$ARM64" "$X86" "$DIST/SHA256SUMS.txt"

gh release view "$TAG" --json url --jq .url
