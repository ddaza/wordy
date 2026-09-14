# Local development assets

## Sample lecture

Long-file development and benchmarking use a lecture recording that each contributor supplies locally under `assets/`, for example:

```text
assets/lecture.mp3
```

The entire `assets/` directory is ignored by Git. Recordings placed there are private to the contributor: they must not be committed, redistributed, quoted in documentation, or uploaded to a transcription provider or any other external service without the recording owner's explicit authorization.

A useful fixture is a real classroom recording of roughly 1.5–2 hours in a common compressed format (MP3/AAC), because it exercises long-file playback, streaming SHA-256 calculation, transcription throughput, caption synchronization, cancellation, and checkpoint/recovery. Treat the original as read-only.

CI and automated tests must not assume such a file exists. Routine tests use small synthetic fixtures; long-running checks against a local recording are invoked deliberately (`make bench`, `scripts/bench-matrix.sh`).

When recording benchmark results under `docs/benchmarks/`, describe the corpus only by duration, format, and bit rate, and record the hardware, macOS version, engine/model configuration, build configuration, and measurement conditions. Do not include the recording's file name, hash, or content.
