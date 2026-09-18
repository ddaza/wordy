# Wordy contributor guidance

## Project intent

Wordy is a native macOS lecture player with Google Drive import, transcription, synchronized captions, and transcript search. Users are nontechnical, and recordings of two hours or longer are expected.

Read `PLAN.md` before making architectural changes. It records confirmed requirements, provisional choices, milestones, and acceptance criteria. Read `README.md` and `docs/scaffold.md` for implemented features, build instructions, and remaining scaffold limitations.

A local, git-ignored sample lecture is documented in `docs/development-assets.md`. It is an opt-in long-file development fixture, not a required CI asset. Follow that document's handling and benchmark-recording rules.

User instructions and accepted decisions take precedence over this guidance. Keep the plan current when implementation evidence changes a provisional choice.

## Product requirements to preserve

- Wordy is a desktop application with **local transcription as the default**. There is no Wordy-operated transcription backend. Optional **Advanced Mode** (OpenRouter BYOK) may upload audio only after the user enables it, stores their own API key, and explicitly consents per job — never as an automatic fallback.
- Do not upload lecture audio or transcripts except through that explicit Advanced Mode path (or user-initiated export). Other network traffic is Google Drive import, pinned model downloads, and signed app updates.
- Users must not need Terminal, package managers, developer tools, or manual model installation. An OpenRouter account is required only for Advanced Mode.
- Support native `arm64` and `x86_64` execution. The provisional minimum is macOS 14; do not raise it or remove Intel support incidentally.
- Preserve responsive playback, scrolling, search, and navigation during inference.
- Preserve original audio timing through decoding, silence handling, chunking, and caption generation.
- Support recovery without discarding completed transcript work.
- Scope bookmarks to the currently open recording using its SHA-256 content identity; never show or mutate bookmarks from another recording.
- Export only the currently open recording's committed transcript as UTF-8 text and identify partial exports clearly.

## Architecture conventions

- Use Swift for application code, SwiftUI for the shell, and AppKit where the transcript surface needs controlled reuse and incremental updates.
- Use AVFoundation for playback and incremental audio preparation.
- Keep local inference behind an engine interface in a bundled XPC service using a pinned `whisper.cpp` integration.
- Keep blocking inference, decoding, indexing, networking, and database queries off the main actor. An async declaration alone does not move blocking work off its executor.
- Bound concurrency, queues, decoded buffers, and messages. Begin with one local inference worker and tune from measurements.
- Store structured transcript data and durable job state in SQLite through GRDB. Keep secrets in Keychain.
- Keep database writes coordinated by the app; return bounded worker results through XPC.
- Normalize all engine output into a common timestamped schema. Persist source version, engine/model version, and configuration.
- Prefer existing native facilities. Add dependencies only for concrete requirements and document significant tradeoffs.

## Transcript and playback correctness

- Use the player's media clock as the caption source of truth; do not use a separately advancing wall-clock timer.
- Use stable segment identity and ordered absolute source timestamps. Handle gaps, seeks, variable speed, and end-of-file explicitly.
- Phrase captions are required. Treat word timing as optional until validated; do not imply experimental timing is exact.
- Reconcile chunk overlap without dropping intentional repetition or duplicating words.
- Persist completed results, their search updates, and checkpoints atomically.
- Treat changed source audio as a new transcript generation.
- Search must map hits back to playable timestamps and account for phrases across caption/chunk boundaries.
- Render visible transcript content efficiently and avoid full-document updates on player ticks.
- Calculate audio SHA-256 incrementally off the main actor and persist it; do not hash an entire multi-hour file into memory or recompute it on every open.
- Include the open recording's content digest in every bookmark read and write. A changed digest is different content and must not inherit bookmarks automatically.
- Validate bookmark times against the source duration and seek through the existing playback controller.
- Generate text exports locally from ordered committed segments. Use a native save panel and an atomic destination replacement so failed exports do not leave truncated files.

## Google Drive, Advanced Mode, and privacy boundaries

- Use a supported external-browser OAuth flow with PKCE/state validation and Keychain token storage.
- `drive.file` is for explicitly authorized files. Do not assume selecting a folder grants access to every child.
- Broad browsing/watched folders require a deliberate permission and verification design.
- Advanced Mode is implemented in `Services/CloudSettings.swift`, `Services/OpenRouterProvider.swift`, and the shared coordinator; see `docs/cloud-transcription.md`. Keep cloud checkpoint restoration paused, require fresh consent for resume/retry, and do not add automatic HTTP retries that can repeat provider charges.
- Advanced Mode: store the OpenRouter API key in Keychain; require per-job consent before upload; normalize cloud segments into the same timestamped schema as local jobs; do not log keys, audio, or transcript contents.
- Do not log audio, transcript contents, tokens, or signed download URLs. Use redacted identifiers and timing metrics for diagnostics.
- Do not add telemetry or crash reporting that could carry transcript text or recording identifiers.
- Do not commit private lecture fixtures, credentials, model weights, or generated artifacts.

## Implementation workflow

1. Inspect existing source, repository status, and applicable instructions before changing files; preserve unrelated user work.
2. Implement the smallest complete slice for the requested milestone. Routine reversible work within the task does not need repeated confirmation.
3. Pin dependencies and record significant architecture decisions or benchmark-driven changes in the plan or `docs/`.
4. Verify behavior in proportion to risk using the actual commands available in the repository. Do not invent successful build/test results.
5. Report what changed, what was verified, and any material remaining limitation.

Open `Wordy.xcodeproj`, select the Wordy scheme and My Mac, then use Run or Test. Run `make help` for command-line development tasks. The primary checks are `make test`, `make test-core`, and `make verify-universal`; `make check` combines native Xcode tests with Universal Release verification. After `make hooks`, Lefthook runs SwiftFormat on commit and `make test-core` plus `make test` on push; `lefthook run check` is the Universal Release gate before tagging. Do not add GitHub Actions that build the app or engine: hosted macOS runners would repeat the pinned whisper.cpp compile and are not a substitute for local Xcode. The inference engine is a pinned `whisper.cpp` release fetched and built by `scripts/fetch-whisper.sh` and `scripts/build-whisper.sh` (CMake required on developer machines only); change the pin only through those scripts and record it in `docs/inference.md`. Speech model download URLs and SHA-256 pins live in `Core/SpeechModels.json`; change the host there if a mirror moves, and keep the checksums in the same file. Benchmarks run through `make bench` / `scripts/bench-matrix.sh`; add results under `docs/benchmarks/` with hardware and conditions. Exact commands and architecture limitations are in `README.md`. Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Config/Version.xcconfig`. `make package` builds universal, arm64, and x86_64 DMGs on a developer Mac; `make release` re-verifies them and publishes with `gh`. Notarized distribution is not automated. Keep these instructions current as targets and scripts change.

## Verification expectations

- Protect timing conversion, overlap reconciliation, search mapping, checkpoint recovery, source invalidation, and migrations with meaningful tests.
- Exercise long recordings, silence, repeated phrases, unsupported formats, worker failure, sleep/wake, disk exhaustion, and interrupted downloads.
- Measure performance in release builds on physical M1 and supported Intel hardware. Rosetta testing alone is insufficient for Intel performance claims.
- Treat `PLAN.md` latency budgets as targets until measured. Include hardware, OS, model, corpus, and test conditions with benchmark results.
- Check aggregate resource use across the app and worker, not just UI-process memory.
- Avoid adding tests that merely mirror trivial presentation code. Run relevant checks and broaden them when changes or failures warrant it.

## Build and release

- Build every bundled executable/native library for both required architectures with compatible deployment targets and portable CPU settings.
- Keep worker packaging, resource access, nested signing, and model loading working in release builds.
- Validate clean installation and first launch without developer tooling installed.
- Direct distribution uses Developer ID signing, hardened runtime, notarization/stapling, and signed Sparkle updates.
- Distinguish preparing a release artifact from publishing it: `make package` writes local DMGs; `make release` re-verifies them and publishes with `gh`. Follow the user's authorized release scope.
- Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` only in `Config/Version.xcconfig`.
- Planning documents do not authorize uploading real lectures or publishing an application.
- Wordy is MIT licensed (`LICENSE`). Keep `THIRD_PARTY_NOTICES.md` current when adding or changing bundled dependencies.
