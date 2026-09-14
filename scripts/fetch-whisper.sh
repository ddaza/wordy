#!/bin/sh
# Fetch the pinned whisper.cpp source release into Vendor/whisper.cpp.
#
# The checkout is intentionally git-ignored; this script is the single source of
# truth for the pinned version. Update WHISPER_VERSION and WHISPER_TARBALL_SHA256
# together and record the change in docs/inference.md.
set -eu

WHISPER_VERSION="v1.9.4"
WHISPER_TARBALL_SHA256="57e280cee375ab02425b806ad5146b99f6eb9357e3c2b31357c8a6af2e2e44ae"
WHISPER_URL="https://github.com/ggml-org/whisper.cpp/archive/refs/tags/${WHISPER_VERSION}.tar.gz"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${WORDY_BUILD_ROOT:-$ROOT/build}"
VENDOR_DIR="$ROOT/Vendor/whisper.cpp"
MARKER="$VENDOR_DIR/.wordy-pinned-version"
TARBALL="$BUILD_ROOT/vendor/whisper-${WHISPER_VERSION}.tar.gz"

if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$WHISPER_VERSION" ]; then
    echo "whisper.cpp ${WHISPER_VERSION} already present in Vendor/whisper.cpp"
    exit 0
fi

mkdir -p "$BUILD_ROOT/vendor"
if [ ! -f "$TARBALL" ]; then
    echo "Downloading whisper.cpp ${WHISPER_VERSION}"
    curl -sSfL -o "$TARBALL.partial" "$WHISPER_URL"
    mv "$TARBALL.partial" "$TARBALL"
fi

ACTUAL="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [ "$ACTUAL" != "$WHISPER_TARBALL_SHA256" ]; then
    rm -f "$TARBALL"
    echo "whisper.cpp tarball checksum mismatch: expected ${WHISPER_TARBALL_SHA256}, got ${ACTUAL}" >&2
    exit 1
fi

rm -rf "$VENDOR_DIR"
mkdir -p "$VENDOR_DIR"
# Only the library sources are needed. Bindings, examples, CI, and sample media
# are excluded to keep the checkout small and free of IDE metadata.
tar -xzf "$TARBALL" --strip-components=1 -C "$VENDOR_DIR" \
    --exclude='*/.idea' --exclude='*/bindings/go' --exclude='*/bindings/java' \
    --exclude='*/bindings/ruby' --exclude='*/bindings/javascript/*' --exclude='*/examples' \
    --exclude='*/tests' --exclude='*/models' --exclude='*/samples' \
    --exclude='*/.github' --exclude='*/.devops' --exclude='*/.pi' \
    --exclude='*/media' --exclude='*/ci' --exclude='*/grammars'
# The top-level CMakeLists.txt configures this template even for library-only builds.
tar -xzf "$TARBALL" --strip-components=1 -C "$VENDOR_DIR" \
    "$(tar -tzf "$TARBALL" | grep 'bindings/javascript/package-tmpl.json$')"
printf '%s\n' "$WHISPER_VERSION" > "$MARKER"
echo "whisper.cpp ${WHISPER_VERSION} extracted to Vendor/whisper.cpp"
