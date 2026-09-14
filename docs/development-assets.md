# Local development assets

## Sample lecture

A locally supplied lecture is available at:

```text
assets/Copy of Lecture 1.mp3
```

Observed metadata on 2026-09-13:

| Property | Value |
| --- | --- |
| Format | MP3 |
| Approximate duration | 1:39:46 (5,986.064 seconds) |
| Bit rate | 192,000 bits per second |
| File size | 143,669,625 bytes |
| SHA-256 | `4ade8de682c99bcc3d873c12cde0e7d3a6641ade99cad045e869bd61770c9c6d` |

Use this recording as an opt-in local fixture for long-file playback, streaming SHA-256 calculation, transcription throughput, caption synchronization, cancellation, and checkpoint/recovery development. Treat the original as read-only. Record the hardware, macOS version, engine/model configuration, build configuration, and measurement conditions with benchmark results.

The entire `assets/` directory is intentionally ignored by Git. CI and automated tests must not assume this file exists, and the recording must not be committed or redistributed. Do not upload it to a transcription provider or any other external service without the user's explicit authorization for that upload. Routine tests should use small synthetic or redistributable fixtures; long-running checks against this lecture must be invoked deliberately.

If the file changes, update the metadata and SHA-256 above before comparing new benchmark results or bookmark identity behavior.
