#!/bin/sh
# Run the Milestone 1 comparison matrix with wordy-bench.
#
# Usage: scripts/bench-matrix.sh AUDIO_FILE OUTPUT_DIR [MODELS_DIR]
#
# Models are read from MODELS_DIR (default assets/models). Each present model is
# run with three chunk policies on the default backend. CPU-only runs are
# limited to the first 10 minutes because on Apple Silicon they only prove the
# CPU code path; they are not Intel measurements.
set -eu

AUDIO="$1"
OUT="$2"
MODELS_DIR="${3:-assets/models}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH="${BENCH:-$ROOT/build/DerivedData/Build/Products/Release/wordy-bench}"
[ -x "$BENCH" ] || { echo "Build wordy-bench first (make bench)" >&2; exit 1; }
mkdir -p "$OUT"

run() {
    echo "== $*" | tee -a "$OUT/matrix.log"
    "$BENCH" --audio "$AUDIO" --output "$OUT" "$@" 2>&1 | tail -n 2 | tee -a "$OUT/matrix.log"
}

for MODEL in whisper-base:ggml-base.bin whisper-small:ggml-small.bin whisper-small-q5_1:ggml-small-q5_1.bin; do
    ID="${MODEL%%:*}"
    FILE="$MODELS_DIR/${MODEL#*:}"
    [ -f "$FILE" ] || { echo "skip $ID (missing $FILE)" | tee -a "$OUT/matrix.log"; continue; }
    for POLICY in "30 2" "60 3" "300 5"; do
        # shellcheck disable=SC2086
        run --model "$FILE" --model-id "$ID" --chunk ${POLICY% *} --overlap ${POLICY#* }
    done
done

for MODEL in whisper-base:ggml-base.bin whisper-small:ggml-small.bin; do
    ID="${MODEL%%:*}"
    FILE="$MODELS_DIR/${MODEL#*:}"
    [ -f "$FILE" ] || continue
    run --model "$FILE" --model-id "$ID" --chunk 60 --overlap 3 --no-gpu --limit 600
done
echo "matrix complete" | tee -a "$OUT/matrix.log"
