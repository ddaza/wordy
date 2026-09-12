# Wordy

A native macOS lecture player and transcription app, targeting macOS 14+ on Intel and Apple Silicon. Local transcription is the default; future cloud acceleration requires explicit consent.

## Start development in Xcode

1. Open `Wordy.xcodeproj` in Xcode 16 or newer with Swift 6 support.
2. Select the **Wordy** scheme and **My Mac** destination.
3. Press **Run** (⌘R). Local development uses ad-hoc signing and does not require a paid developer account.
4. Choose **Import Audio…** (⌘O) to play a local recording, or **Explore Sample** to inspect and search the sample transcript.
5. Open **Wordy → Settings…** to check the bundled XPC service connection.

No external packages or model downloads are needed for this scaffold. Open the Xcode project for the full app; `Package.swift` exposes only the shared core and its tests.

## What works now

- Native library window, local audio file selection, asynchronous media inspection, and AVPlayer playback.
- Seeking, skip controls, speed, volume, and current media time.
- A reusable AppKit transcript view, phrase search, search result navigation, and follow-playback wiring.
- An explicitly labeled sample transcript with no associated audio.
- Validated caption intervals, binary-search time lookup, and search across caption boundaries.
- A bundled XPC service and readiness handshake, with timeout/interruption handling.
- A default-local transcription request contract that rejects unconsented cloud mode.
- Shared core tests through Xcode or Swift Package Manager.
- Debug builds for the development Mac; Release builds configured for Intel and Apple Silicon.

## Scaffold limitations

Actual transcription, model installation, Google Drive authorization/downloads, cloud processing, persistent storage, exports, and automatic updates are not implemented yet. Imported recordings have no generated captions. The sample is never substituted for a real transcript.

The library is session-only and references the original audio files without copying them. Keep imported files accessible while listening. Playback state is not restored after quitting. The production implementation will add managed caching and GRDB/FTS5 persistence.

Search currently runs over an in-memory document on a background task and returns one hit per matching passage. It is a development implementation, not the planned 1,000-lecture FTS5 index. Text can be selected within individual passage views; cross-passage selection and full accessibility verification remain future work.

The development bundle uses ad-hoc signing and is not notarized or ready for public distribution. App Sandbox is not enabled in this scaffold; sandbox entitlements and worker file access must be evaluated with the inference integration. Xcode may disable hardened runtime for ad-hoc signatures even though the release setting is enabled; production signing must verify the actual result.

## Developer commands

Xcode remains the build system. The Makefile provides short names for its common development commands:

```sh
make help              # List all commands
make run               # Build and open the Debug app
make test              # Run the Xcode test scheme natively
make test-core         # Run fast shared-core tests with SwiftPM
make build-arm64       # Cross-compile an Apple Silicon Release app
make build-x86_64      # Cross-compile an Intel Release app
make verify-universal  # Build and verify one app containing both architectures
make check             # Native tests plus Universal Release verification
```

Use `make test-arm64` on Apple Silicon. `make test-x86_64` requires an Intel Mac or an x86_64 destination made available by Rosetta. Cross-compilation proves that an architecture builds; it does not replace running and profiling on physical hardware.

Run `make xcode` to open the project, or use Xcode directly: **⌘B** builds, **⌘R** runs, and **⌘U** tests. `make doctor`, `make list`, `make analyze`, and `make clean` cover toolchain diagnostics, project inspection, static analysis, and build cleanup. Run `make help` for the complete list; generated products stay under `build/`.

Xcode output is concise by default. Add `XCODE_FLAGS=` to a command when you need the complete build log, for example `make build XCODE_FLAGS=`. Override `BUILD_ROOT` to place generated files elsewhere.

The Universal Release app is produced at `build/DerivedData/Build/Products/Release/Wordy.app`. Users run an application bundle; Make targets and underlying commands are only for development and automation.

## Layout

| Path | Purpose |
| --- | --- |
| `Makefile` | Short developer commands wrapping Xcode and SwiftPM. |
| `App/` | SwiftUI app entry point and scene composition. |
| `Features/` | Library, player, transcript surface, and settings. |
| `Core/` | Domain types, caption timeline, scaffold search, provider/XPC contracts. |
| `Services/` | Media inspection and XPC client. |
| `TranscriptionService/` | XPC executable; currently reports that inference is unavailable. |
| `Config/` | App and worker property lists. |
| `Tests/` | Timing, validation, search, and cloud-consent tests. |
| `Wordy.xcodeproj/` | App/worker/test targets and shared scheme. |

Xcode synchronized folders include new source files automatically within their target folders. `Core/` is compiled into each relevant target; SwiftPM also exposes it as `WordyCore`. Keep it independent of UI frameworks.

## Next implementation slice

Integrate a pinned `whisper.cpp` build into the worker, add the model manager and bounded audio decoding, and replace the readiness-only contract with versioned transcription messages. Add actual timestamped results to imported lectures, then implement atomic persistence/checkpoints and benchmark full two-hour recordings on physical Intel and M1 Macs.

See [PLAN.md](PLAN.md) for milestones and acceptance targets, [AGENTS.md](AGENTS.md) for contributor guidance, and [docs/scaffold.md](docs/scaffold.md) for the current architecture boundary and verification record.
