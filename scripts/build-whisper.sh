#!/bin/sh
# Build the pinned whisper.cpp + ggml sources as one universal static library.
#
# Usage: scripts/build-whisper.sh [arch ...]
#   Architectures default to $ARCHS (set by Xcode) or "arm64 x86_64".
#
# Per-architecture settings are deliberate and portable:
#   arm64  : Metal (embedded shader library), Accelerate BLAS, NEON baseline.
#   x86_64 : Accelerate BLAS, fixed AVX2/FMA/F16C/BMI2 baseline (Haswell+), no
#            AVX-512 and no -march=native, so every Intel Mac that runs macOS 14
#            executes the same code.
#
# Output: build/whisper/lib/libwordy_whisper.a and build/whisper/include/*.h
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${WORDY_BUILD_ROOT:-$ROOT/build}"
export WORDY_BUILD_ROOT="$BUILD_ROOT"
VENDOR_DIR="$ROOT/Vendor/whisper.cpp"
OUT_DIR="$BUILD_ROOT/whisper"
LIB_DIR="$OUT_DIR/lib"
INCLUDE_DIR="$OUT_DIR/include"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
UNIVERSAL_LIB="$LIB_DIR/libwordy_whisper.a"

if [ "$#" -gt 0 ]; then
    WANTED="$*"
else
    WANTED="${ARCHS:-arm64 x86_64}"
fi

"$ROOT/scripts/fetch-whisper.sh"
PINNED="$(cat "$VENDOR_DIR/.wordy-pinned-version")"

# Fast path: the universal library exists, was built from the pinned version,
# and already contains every requested slice.
if [ -f "$UNIVERSAL_LIB" ] && [ -f "$LIB_DIR/.version" ] && [ "$(cat "$LIB_DIR/.version")" = "$PINNED" ]; then
    MISSING=""
    for ARCH in $WANTED; do
        if ! lipo "$UNIVERSAL_LIB" -verify_arch "$ARCH" 2>/dev/null; then
            MISSING="$MISSING $ARCH"
        fi
    done
    if [ -z "$MISSING" ]; then
        echo "libwordy_whisper.a is current for: $WANTED"
        exit 0
    fi
fi

command -v cmake >/dev/null 2>&1 || {
    echo "cmake is required to build the bundled inference engine (developer machines only)." >&2
    exit 1
}

# Xcode exports SDKROOT/toolchain variables that confuse a nested CMake configure.
unset SDKROOT CC CXX CFLAGS CXXFLAGS LDFLAGS MACOSX_DEPLOYMENT_TARGET || true
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

build_arch() {
    ARCH="$1"
    SRC_BUILD="$OUT_DIR/$ARCH"
    case "$ARCH" in
        arm64)
            ARCH_FLAGS="-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_METAL_NDEBUG=ON \
                -DGGML_METAL_MACOSX_VERSION_MIN=$DEPLOYMENT_TARGET"
            ;;
        x86_64)
            ARCH_FLAGS="-DGGML_METAL=OFF -DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON \
                -DGGML_F16C=ON -DGGML_BMI2=ON -DGGML_AVX512=OFF -DGGML_AVX_VNNI=OFF"
            ;;
        *)
            echo "Unsupported architecture: $ARCH" >&2
            exit 1
            ;;
    esac
    echo "Configuring whisper.cpp $PINNED for $ARCH"
    # shellcheck disable=SC2086
    cmake -S "$VENDOR_DIR" -B "$SRC_BUILD" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DGGML_NATIVE=OFF \
        -DGGML_OPENMP=OFF \
        -DGGML_CCACHE=OFF \
        -DGGML_ACCELERATE=ON \
        -DGGML_BLAS=ON \
        -DGGML_BLAS_VENDOR=Apple \
        -DWHISPER_BUILD_EXAMPLES=OFF \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_SERVER=OFF \
        -DWHISPER_COREML=OFF \
        $ARCH_FLAGS >"$SRC_BUILD.configure.log" 2>&1 || {
        cat "$SRC_BUILD.configure.log" >&2
        exit 1
    }
    echo "Building whisper.cpp for $ARCH"
    cmake --build "$SRC_BUILD" --config Release --parallel >"$SRC_BUILD.build.log" 2>&1 || {
        tail -n 60 "$SRC_BUILD.build.log" >&2
        exit 1
    }
    # Merge every static archive into one per-architecture library so the app
    # links a single artifact regardless of which backends exist per slice.
    ARCHIVES=""
    for ARCHIVE in $(find "$SRC_BUILD" -name '*.a' -type f ! -name 'libparakeet.a' ! -name 'libwordy_whisper-*' | sort); do
        ARCHIVES="$ARCHIVES $ARCHIVE"
    done
    [ -n "$ARCHIVES" ] || {
        echo "No static archives produced for $ARCH" >&2
        exit 1
    }
    # shellcheck disable=SC2086
    libtool -static -no_warning_for_no_symbols -o "$SRC_BUILD/libwordy_whisper-$ARCH.a" $ARCHIVES
}

mkdir -p "$LIB_DIR" "$INCLUDE_DIR"
SLICES=""
for ARCH in $WANTED; do
    if [ ! -f "$OUT_DIR/$ARCH/libwordy_whisper-$ARCH.a" ] || [ "$(cat "$LIB_DIR/.version" 2>/dev/null || true)" != "$PINNED" ]; then
        build_arch "$ARCH"
    fi
    SLICES="$SLICES $OUT_DIR/$ARCH/libwordy_whisper-$ARCH.a"
done
# Keep previously built slices so Debug (single arch) and Release (universal)
# builds share one output.
if [ -f "$UNIVERSAL_LIB" ] && [ "$(cat "$LIB_DIR/.version" 2>/dev/null || true)" = "$PINNED" ]; then
    for EXISTING in arm64 x86_64; do
        case " $WANTED " in *" $EXISTING "*) continue ;; esac
        if lipo "$UNIVERSAL_LIB" -verify_arch "$EXISTING" 2>/dev/null; then
            lipo "$UNIVERSAL_LIB" -thin "$EXISTING" -output "$OUT_DIR/libwordy_whisper-$EXISTING.thin.a"
            SLICES="$SLICES $OUT_DIR/libwordy_whisper-$EXISTING.thin.a"
        fi
    done
fi
# shellcheck disable=SC2086
lipo -create $SLICES -output "$UNIVERSAL_LIB.tmp"
mv "$UNIVERSAL_LIB.tmp" "$UNIVERSAL_LIB"
rm -f "$OUT_DIR"/*.thin.a

cp "$VENDOR_DIR/include/whisper.h" "$INCLUDE_DIR/"
cp "$VENDOR_DIR/ggml/include/"*.h "$INCLUDE_DIR/"
printf '%s\n' "$PINNED" > "$LIB_DIR/.version"
lipo -info "$UNIVERSAL_LIB"
