# Local inference: engine, worker, checkpoints, and Milestone 1 evidence

## Pinned engine

| Item | Value |
| --- | --- |
| Engine | [whisper.cpp](https://github.com/ggml-org/whisper.cpp) `v1.9.4` (commit `927cfce34f31707e17f2bff35c349632fb9e2c3a`, ggml 0.23.0) |
| Source pin | `scripts/fetch-whisper.sh` downloads the GitHub tag tarball and verifies SHA-256 `57e280cee375ab02425b806ad5146b99f6eb9357e3c2b31357c8a6af2e2e44ae` |
| Checkout | `Vendor/whisper.cpp/` (git-ignored; only library sources are extracted) |
| Build | `scripts/build-whisper.sh` → `build/whisper/lib/libwordy_whisper.a` (universal) and `build/whisper/include/` |
| Xcode | Aggregate target `WhisperEngine` runs the build script; `WordyTranscriptionService` and `wordy-bench` depend on it and link the static library via a bridging header |

The engine reports its version string as `1.9.4-dev` because the tarball build has no git metadata; the pinned tag is authoritative.

### Per-architecture settings

| Setting | arm64 | x86_64 |
| --- | --- | --- |
| GPU | Metal, shader library embedded in the binary (`GGML_METAL_EMBED_LIBRARY`), flash attention on | Off (`GGML_METAL=OFF`) |
| BLAS | Accelerate | Accelerate |
| CPU ISA | NEON baseline (`GGML_NATIVE=OFF`) | Fixed AVX2 + FMA + F16C + BMI2 + SSE4.2; AVX-512 and AVX-VNNI off; no `-march=native` |
| Threads | OpenMP off; ggml's own thread pool | same |
| Deployment target | macOS 14.0 | macOS 14.0 |

Every Intel Mac that runs macOS 14 has a Haswell-or-newer CPU, so the AVX2/FMA/F16C baseline is safe. Runtime-dispatched CPU variants (`GGML_CPU_ALL_VARIANTS`) require dynamic backend loading and were not adopted for the bundled static build.

Rebuild after changing the pin: `make engine-clean engine`. The Xcode script phase is a fast no-op when `build/whisper/lib/libwordy_whisper.a` already contains the requested slices for the pinned version.

## Speech model manifest

Models are the multilingual ggml conversions published by the whisper.cpp project. The download host, filenames, recommended IDs, and SHA-256 pins live in `Core/SpeechModels.json` (bundled into the app). Change `downloadBaseURL` there if the host moves; an optional per-model `downloadURL` overrides the base. The app only activates a download whose SHA-256 matches the pin — a new file at the same URL is discarded, so already-installed models keep working.

| ID | File | Bytes | SHA-256 | Upstream SHA-1 |
| --- | --- | --- | --- | --- |
| `whisper-base` | `ggml-base.bin` | 147,951,465 | `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe` | `465707469ff3a37a2b9b8d8f89f2f99de7299dac` |
| `whisper-small` | `ggml-small.bin` | 487,601,967 | `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b` | `55356645c2b361a969dfd0ef2c5a50d530afd8d5` |
| `whisper-small-q5_1` | `ggml-small-q5_1.bin` | 190,085,487 | `ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb` | not listed upstream |

Digests were computed on 2026-09-13 from files whose SHA-1 matched `models/README.md` in the pinned whisper.cpp release (the quantized file has no upstream digest and is pinned only by its measured SHA-256).

Installation flow (`Services/ModelManager.swift`): download to `<Application Support>/Wordy/Models/<file>.partial` with HTTP range resume → stream SHA-256 → atomic `replaceItemAt` to the final name. A file at the final path is therefore always a verified model. Downloads are cancellable; a checksum mismatch discards the file. Settings can download every catalog model; only the one marked **In use** (`wordy.selectedModelID`) is passed to the worker. The first installed model is selected automatically; **Use** switches. Removing the in-use model leaves none selected until another is chosen.

Provisional recommendation offered when nothing is selected yet: `whisper-small` on Apple Silicon, `whisper-base` on Intel, pending the physical-hardware measurements below.

## Worker protocol

`Core/TranscriptionMessages.swift` defines protocol version 1. Messages are JSON `Data` over `NSXPCConnection`:

- `describeEngine` → `EngineDescription` (engine name/version, ggml system info, GPU compiled in).
- `transcribeChunk(request)` → `ChunkTranscriptionResult` or a user-presentable failure string. The request carries only a file path, a source time range (≤ 600 s), the model path/ID, language, thread count, and GPU flag. Results carry absolute-time `RawSegment`s, detected language, engine/model identity, and `ChunkMetrics` (decode ms, model load ms, inference ms, worker footprint).
- `cancel(jobID)` flips an abort flag read by ggml's abort callback.
- `unloadModel` frees the context; the worker also unloads after 5 idle minutes.

The worker (`Inference/`) decodes each chunk with `AVAssetReader` to 16 kHz mono float and runs `whisper_full` on one serial utility-QoS queue. Peak worker memory is bounded by model size plus one chunk (60 s × 16 kHz × 4 B ≈ 3.8 MB). The first decoded sample's presentation timestamp anchors absolute times, so overlap and reader offsets cannot shift captions.

Non-speech token suppression (`suppress_nst`) and blank suppression are on; bracketed markers that still appear are dropped during reconciliation rather than shown as captions. Greedy decoding with whisper.cpp's default temperature fallback is used; beam search was not evaluated in Milestone 1.

## Chunking and reconciliation

`ChunkPolicy(chunkSeconds, overlapSeconds)` produces owned half-open ranges that tile `[0, duration)` exactly once, each decoded with symmetric overlap context (`Core/ChunkPlan.swift`). A tail shorter than `min(chunk/4, 10 s)` merges into the previous chunk. Local jobs use 60 s + 3 s; cloud jobs use 60 s + 10 s.

`ChunkReconciler.commit` attributes a raw segment to the chunk that heard it *start*, then stitches a re-hear by dropping at most the overlap word budget (about 3–4 words at 3 s). Checkpoints store per-section engine `raw` beside committed captions. The current rule, isolation method, and rejected alternatives (midpoint attribution, time-proportional deletion, a separate capture script, 50 s + 15 s cloud windows) are in `docs/caption-pipeline.md`.

Word-level timing is not requested yet; captions remain phrase-level. Carrying decoder context between chunks (`initial_prompt`) is not enabled.

## Checkpoints and recovery

`TranscriptCheckpoint` (`Core/TranscriptCheckpoint.swift`) records the audio SHA-256, source duration, `TranscriptionConfiguration` (engine, version, model, language, policy), chunk count, committed chunk count, committed segments, and optional per-section `raw` engine output. Chunks commit strictly in order; committing out of order or producing an overlapping timeline throws before anything is persisted.

`Services/CheckpointStore.swift` writes `<Application Support>/Wordy/Transcripts/<sha256>.json` through a temporary sibling and `replaceItemAt`, so a crash mid-write leaves the previous checkpoint intact. `TranscriptionCoordinator` persists the checkpoint *before* publishing new segments to the UI, then requests the next chunk. Consequences:

- Quitting, a worker crash, or a pause loses at most the in-flight chunk.
- Reopening the same bytes (any path or name) restores committed passages immediately and resumes from `committedChunkCount`.
- A complete checkpoint is restored regardless of the current configuration; an incomplete one resumes only if the configuration matches, otherwise a new generation starts.
- A different SHA-256 is a different recording and never inherits a checkpoint.

Worker interruption (`NSXPCConnectionInterrupted`) is retried twice for the same chunk; the XPC service relaunches on demand.

Recovery walkthrough (2026-09-14, Release build, `base`): killing the worker with `SIGKILL` at chunk 68 of 100 and relaunching the app resumed at chunk 68 with all 68 committed sections restored. The same walkthrough exposed a crash: XPC invoked the connection's error handler off the main thread, and because that closure had been formed inside a `@MainActor` method without `@Sendable`, Swift 6's inferred isolation trapped (`Block was expected to execute on queue main-thread`, `SIGTRAP`). `WorkerClient` now declares every XPC handler `@Sendable` and hops to the main actor explicitly. Any future callback handed to XPC, AVFoundation, or other system code from a main-actor context must follow the same rule.

Milestone 2 replaces the JSON document with GRDB while keeping these invariants (ordered commits, atomic persistence, digest-keyed generations).

## Benchmarking

`wordy-bench` (Release, `Benchmarks/`) runs the identical decode → whisper → reconcile pipeline in-process and writes `BenchmarkRecord` JSON plus a timestamped transcript. `scripts/bench-matrix.sh AUDIO OUT` runs the model × policy matrix. The app writes the same record (`source: "Wordy.app via XPC worker"`, including main-thread scheduling delay percentiles sampled at 10 Hz) to `<Application Support>/Wordy/Benchmarks/` when a job completes.

Real-time factor (RTF) = processing seconds ÷ audio seconds; lower is faster (0.05 = 20× real time).

### Results: Apple M4 Max (available development hardware)

See the tables recorded in `docs/benchmarks/2026-09-13-m4max.md`.

### Outstanding hardware coverage

Milestone 1 requires physical **M1 (8 GB)** and **Intel** runs. Neither machine was available during this slice; the Intel slice is cross-compiled and verified for architecture, deployment target, and signature only. The recommendation below is therefore provisional for those tiers and must be confirmed by running `scripts/bench-matrix.sh` on each machine and adding the records to `docs/benchmarks/`.
