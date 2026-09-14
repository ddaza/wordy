# Wordy contributor guidance

## Project intent

Wordy is a native macOS lecture player with Google Drive import, transcription, synchronized captions, and transcript search. Users are nontechnical, and recordings of two hours or longer are expected.

Read `PLAN.md` before making architectural changes. It records confirmed requirements, provisional choices, milestones, and acceptance criteria. Read `README.md` and `docs/scaffold.md` for implemented features, build instructions, and remaining scaffold limitations.

A local, git-ignored sample lecture is documented in `docs/development-assets.md`. It is an opt-in long-file development fixture, not a required CI asset. Follow that document's handling and benchmark-recording rules.

User instructions and accepted decisions take precedence over this guidance. Keep the plan current when implementation evidence changes a provisional choice.

## Product requirements to preserve

- Local transcription is the default. Cloud acceleration is optional and explicitly selected per recording or batch.
- Never silently upload lecture audio or transcripts because local processing is slow, unavailable, or has failed.
- Users must not need Terminal, package managers, developer tools, provider API keys, or manual model installation.
- Support native `arm64` and `x86_64` execution. The provisional minimum is macOS 14; do not raise it or remove Intel support incidentally.
- Preserve responsive playback, scrolling, search, and navigation during inference.
- Preserve original audio timing through decoding, silence handling, chunking, and caption generation.
- Support recovery without discarding completed transcript work.
- Scope bookmarks to the currently open recording using its SHA-256 content identity; never show or mutate bookmarks from another recording.
- Export only the currently open recording's committed transcript as UTF-8 text and identify partial exports clearly.

## Architecture conventions

- Use Swift for application code, SwiftUI for the shell, and AppKit where the transcript surface needs controlled reuse and incremental updates.
- Use AVFoundation for playback and incremental audio preparation.
- Keep local inference behind a provider interface in a bundled XPC service using a pinned `whisper.cpp` integration.
- Keep blocking inference, decoding, indexing, networking, and database queries off the main actor. An async declaration alone does not move blocking work off its executor.
- Bound concurrency, queues, decoded buffers, and messages. Begin with one local inference worker and tune from measurements.
- Store structured transcript data and durable job state in SQLite through GRDB. Keep secrets in Keychain.
- Keep database writes coordinated by the app; return bounded worker results through XPC.
- Normalize all provider output into a common timestamped schema. Persist source version, engine/model version, and configuration.
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

## Google Drive and cloud boundaries

- Use a supported external-browser OAuth flow with PKCE/state validation and Keychain token storage.
- `drive.file` is for explicitly authorized files. Do not assume selecting a folder grants access to every child.
- Broad browsing/watched folders require a deliberate permission and verification design.
- Keep transcription provider secrets on the backend. Google Drive authorization is not generic backend authentication.
- Cloud requests must follow the explicit user choice, show applicable cost/allowance, and accurately describe data handling.
- Do not log audio, transcript contents, tokens, signed download URLs, or provider secrets. Use redacted identifiers and timing metrics for diagnostics.
- Do not commit private lecture fixtures, credentials, model weights, or generated artifacts.

## Implementation workflow

1. Inspect existing source, repository status, and applicable instructions before changing files; preserve unrelated user work.
2. Implement the smallest complete slice for the requested milestone. Routine reversible work within the task does not need repeated confirmation.
3. Pin dependencies and record significant architecture decisions or benchmark-driven changes in the plan or `docs/`.
4. Verify behavior in proportion to risk using the actual commands available in the repository. Do not invent successful build/test results.
5. Report what changed, what was verified, and any material remaining limitation.

Open `Wordy.xcodeproj`, select the Wordy scheme and My Mac, then use Run or Test. Run `make help` for command-line development tasks. The primary checks are `make test`, `make test-core`, and `make verify-universal`; `make check` combines native Xcode tests with Universal Release verification. Exact commands and architecture limitations are in `README.md`. No benchmark or production release automation is established yet. Keep these instructions current as targets and scripts change.

## Verification expectations

- Protect timing conversion, overlap reconciliation, search mapping, checkpoint recovery, source invalidation, migrations, and explicit cloud selection with meaningful tests.
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
- Distinguish preparing a release artifact from publishing it. Follow the user's authorized release scope.
- Planning documents do not authorize uploading real lectures, spending provider funds, or publishing an application.
