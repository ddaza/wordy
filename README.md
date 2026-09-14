# Wordy

A native macOS lecture player and transcription app, targeting macOS 14+ on Intel and Apple Silicon. Transcription runs entirely on your Mac; recordings and transcripts are never uploaded. Open source under the [MIT License](LICENSE).

## Start development in Xcode

1. Install CMake (`brew install cmake`); it builds the bundled inference engine once. Users of the finished app never need it.
2. Open `Wordy.xcodeproj` in Xcode 16 or newer with Swift 6 support.
3. Select the **Wordy** scheme and **My Mac** destination.
4. Press **Run** (⌘R). The first build fetches the pinned `whisper.cpp` release into `Vendor/` and compiles it (a few minutes); later builds reuse it. Local development uses ad-hoc signing and does not require a paid developer account.
5. Choose **Import Audio…** (⌘O) to import a recording. Open **Wordy → Settings…** to download the recommended speech model; transcription starts automatically once a model is installed.

`Package.swift` exposes only the shared core and its tests; the app, worker, and benchmark tool are Xcode targets.

## What works now

- Native library window, local audio file selection, asynchronous media inspection, and AVPlayer playback with seeking, skip, speed, and volume.
- Local transcription through a bundled XPC worker running pinned `whisper.cpp` (Metal on Apple Silicon, AVX2 CPU path on Intel).
- One-click model download from a pinned manifest with resume, SHA-256 verification, and atomic activation.
- Incremental results: passages appear per completed section while later sections stay visibly pending; playback and search work on the partial transcript.
- Checkpointed jobs keyed by the recording's SHA-256: pause, resume, quit, worker crash, and re-import all continue from the last committed section.
- Reusable AppKit transcript view with incremental row insertion, phrase search across passage boundaries, search-to-seek, follow-playback, and per-recording bookmarks (pin beside a passage timestamp; collapsible inspector on the right when the open recording has pins).
- `wordy-bench` command-line harness and `scripts/bench-matrix.sh` for repeatable engine/model/chunk-policy measurements.
- Universal Release builds (`arm64` + `x86_64`) of the app, worker, and engine with macOS 14.0 minimum.

## Current limitations

Google Drive import, GRDB/FTS5 persistence, exports, word-level timing, and automatic updates are not implemented yet. The library is session-only and references original audio files without copying them; transcripts persist as per-recording checkpoint documents and are restored when the same file bytes are imported again. Playback position is not restored after quitting.

Search runs over the in-memory transcript of the open lecture on a background task; it is not the planned library-wide FTS5 index.

Physical M1 and Intel measurements are still outstanding; see `docs/inference.md`. The development bundle uses ad-hoc signing, is not notarized, and does not enable App Sandbox.

## Developer commands

Xcode remains the build system. The Makefile provides short names for its common development commands:

```sh
make help              # List all commands
make run               # Build and open the Debug app
make test              # Run the Xcode test scheme natively
make test-core         # Run fast shared-core tests with SwiftPM
make engine            # Fetch and build the pinned whisper.cpp universal static library
make bench             # Build wordy-bench; add AUDIO=… MODEL=… MODEL_ID=… to run it
make build-arm64       # Cross-compile an Apple Silicon Release app
make build-x86_64      # Cross-compile an Intel Release app
make verify-universal  # Build and verify one app containing both architectures
make check             # Native tests plus Universal Release verification
```

Use `make test-arm64` on Apple Silicon. `make test-x86_64` requires an Intel Mac or an x86_64 destination made available by Rosetta. Cross-compilation proves that an architecture builds; it does not replace running and profiling on physical hardware.

`Wordy.app --open /path/to/lecture.mp3` imports a file at launch for manual testing and automation.

Run `make xcode` to open the project, or use Xcode directly: **⌘B** builds, **⌘R** runs, and **⌘U** tests. `make doctor`, `make list`, `make analyze`, and `make clean` cover toolchain diagnostics, project inspection, static analysis, and build cleanup. Generated products stay under `build/`; the vendored engine source lives in the git-ignored `Vendor/whisper.cpp/`.

Xcode output is concise by default. Add `XCODE_FLAGS=` to a command when you need the complete build log, for example `make build XCODE_FLAGS=`.

The Universal Release app is produced at `build/DerivedData/Build/Products/Release/Wordy.app`.

## Layout

| Path | Purpose |
| --- | --- |
| `Makefile` | Short developer commands wrapping Xcode, SwiftPM, and the engine scripts. |
| `App/` | SwiftUI app entry point and scene composition. |
| `Features/` | Library, player, transcript surface, transcription status, and settings. |
| `Core/` | Domain types, caption timeline, chunk planning/reconciliation, checkpoint model, bookmarks, worker messages, model catalog (`SpeechModels.json`), digests, benchmark record. |
| `Services/` | Media inspection, XPC client, model manager, checkpoint store, bookmark store, transcription coordinator. |
| `Inference/` | whisper.cpp binding, bounded audio decoding, and the serial inference session shared by the worker and benchmark tool. |
| `TranscriptionService/` | XPC worker entry point. |
| `Benchmarks/` | `wordy-bench` command-line harness. |
| `scripts/` | Pinned engine fetch/build and benchmark matrix scripts. |
| `Vendor/` | Git-ignored pinned `whisper.cpp` checkout produced by `scripts/fetch-whisper.sh`. |
| `Config/` | App and worker property lists. |
| `Tests/` | Timing, search, chunking, reconciliation, checkpoint, bookmarks, digest, and message tests. |
| `LICENSE`, `THIRD_PARTY_NOTICES.md` | MIT license for Wordy and notices for bundled dependencies (`whisper.cpp`/ggml, speech models). |
| `docs/` | Scaffold record, inference/engine documentation, benchmark records, development assets. |
| `assets/` | Git-ignored local recordings and model files for deliberate manual and performance checks. |

Xcode synchronized folders include new source files automatically within their target folders. `Core/` is compiled into each relevant target; SwiftPM also exposes it as `WordyCore`. Keep it independent of UI frameworks.

## Next implementation slice

Milestone 2: GRDB schema and migrations replacing the JSON checkpoint and bookmark documents, durable job coordinator and cache, FTS5 search, exports, playback-state restore, and the remaining recovery tests. Confirm the engine recommendation on physical M1 and Intel hardware first.

See [PLAN.md](PLAN.md) for milestones and acceptance targets, [AGENTS.md](AGENTS.md) for contributor guidance, [docs/inference.md](docs/inference.md) for the engine, worker protocol, checkpoint design, and benchmark procedure, [docs/scaffold.md](docs/scaffold.md) for the original scaffold record, and [docs/development-assets.md](docs/development-assets.md) for local fixtures.
