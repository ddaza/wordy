#!/bin/sh
# Write SHA256SUMS.txt and a GitHub release notes draft for make release.
#
# Usage: scripts/write-release-metadata.sh <version> <dist-dir>
set -eu

VERSION="${1:-}"
DIST="${2:-}"
if [ -z "$VERSION" ] || [ ! -d "$DIST" ]; then
    echo "Usage: scripts/write-release-metadata.sh <version> <dist-dir>" >&2
    exit 1
fi

UNIVERSAL="Wordy-${VERSION}-macos-universal.dmg"
ARM64="Wordy-${VERSION}-macos-arm64.dmg"
X86="Wordy-${VERSION}-macos-x86_64.dmg"
for dmg in "$UNIVERSAL" "$ARM64" "$X86"; do
    if [ ! -f "$DIST/$dmg" ]; then
        echo "missing $DIST/$dmg" >&2
        exit 1
    fi
done

(
    cd "$DIST"
    shasum -a 256 "$UNIVERSAL" "$ARM64" "$X86" >SHA256SUMS.txt
)

cat >"$DIST/RELEASE_NOTES.md" <<EOF
macOS 14+ lecture player. Transcription runs on your Mac; recordings are never uploaded.

## Packages

- \`$UNIVERSAL\` — Apple Silicon and Intel
- \`$ARM64\` — Apple Silicon only
- \`$X86\` — Intel only

Open the disk image and drag Wordy into Applications. These builds are **ad-hoc signed and not notarized**. Gatekeeper will warn until you right-click the app and choose Open. Speech models download in the app; they are not in these images.

## Checksums

\`\`\`
$(cat "$DIST/SHA256SUMS.txt")
\`\`\`
EOF

printf 'Wrote checksums and notes for v%s in %s\n' "$VERSION" "$DIST"
cat "$DIST/SHA256SUMS.txt"
