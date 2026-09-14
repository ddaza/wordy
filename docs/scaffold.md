# Scaffold decisions and verification

This document records the initial scaffold as built. The Milestone 1 slice that followed (pinned whisper.cpp engine, XPC inference protocol, model manager, checkpointed jobs, benchmark harness) is documented in `docs/inference.md`; statements below about missing inference or a readiness-only worker describe the scaffold stage, not the current tree.

## Scope

This scaffold starts development; it does not complete Milestone 1. Inference, model packaging, two-hour transcription, checkpoint recovery, and physical Intel/M1 performance validation remain outstanding.

The runnable slice is a native app with local media import/playback, an independent sample transcript/search view, and a bundled readiness-only XPC service. Local media is not uploaded, copied into managed storage, or transcribed.

## Deliberate boundaries

- Keep the initial build dependency-free. Add pinned whisper.cpp and GRDB versions when their implementation slices begin, rather than introducing unused packages or pretending those integrations already exist.
- Use an Xcode project with synchronized source groups and an embedded XPC target. A separate Swift package supports quick core tests without building the application.
- Use macOS 14 as the deployment target with Swift 6 strict concurrency. Compile Release for both `arm64` and `x86_64`.
- The media inspector is an actor and awaits AVFoundation metadata loading; it does not decode entire recordings on the main actor.
- Playback time drives caption selection. Timeline lookup is logarithmic; only active passage identity changes cause highlight updates.
- In-memory phrase search is a temporary adapter for the sample. It joins captions with offsets to retain search-to-time mapping across caption boundaries. It does not satisfy the future database/search scalability milestone.
- The worker reports unavailable inference honestly. There are no fake completed jobs or synthetic transcripts attached to imported recordings.
- The request-level consent flag guards construction but is not a complete cloud security system. A real integration needs UI consent, authenticated backend authorization, job ownership, and provider data-handling controls.
- Worker readiness uses a bounded timeout and finishes its continuation at most once. Actual inference needs a separate durable job protocol, cancellation, versioned results, and recovery semantics.
- Local development uses ad-hoc signatures with no App Sandbox entitlements. Public distribution needs a real signing identity, notarization, and validated runtime/resource access.

## Manual smoke checklist

- Launch from Xcode and resize the library/transcript panes.
- Explore the sample, search for `local transcription`, clear search, and copy text.
- Import playable MP3/M4A/WAV audio and verify play/pause, seeking, skip, speed, volume, and end-of-file.
- Import an unsupported/corrupt file and confirm an actionable error without losing the session library.
- Switch recordings while playing and confirm the previous recording stops.
- Open Settings and confirm `Service connected. Speech model not installed.` appears for the local engine.
- Confirm sample playback controls are disabled, and real recordings show a pending-transcription explanation.

Builds and automated core tests do not substitute for these GUI checks or real audio/timing performance measurements.

## Verified during scaffolding

Environment: Xcode 26.6, Swift 6.3.3, macOS 26.6.2 on an arm64 MacBook Pro.

- Debug application build passed.
- SwiftPM core tests: 6 passed, 0 failed.
- Xcode Wordy scheme tests: 6 passed, 0 failed, 0 skipped.
- Universal Release application build passed.
- `lipo` confirmed `x86_64` and `arm64` slices in both the app executable and its embedded XPC executable.
- `vtool` confirmed macOS 14.0 minimum deployment in both app slices.
- Recursive strict code-signature verification passed for the ad-hoc-signed app and worker.
- App/worker property lists and the Xcode project passed property-list validation.

GUI playback, the live XPC handshake, physical Intel execution, macOS 14 execution, and long-file performance have not been manually verified. No transcription models or third-party packages were downloaded, and no audio was uploaded.
