# Caption pipeline: raw engine output and overlap stitch

This records how Wordy turns chunked ASR into committed captions, how to tell a planner/ASR miss from a stitch bug, and which alternatives were tried and rejected. Local whisper.cpp and Advanced Mode (OpenRouter) share the same stitch. See `docs/inference.md` for the worker and checkpoints, and `docs/cloud-transcription.md` for upload bounds and consent.

Private lecture audio stays under git-ignored `assets/`. Do not commit recordings, quote them, or upload them without the recording owner's authorization. Functional caption tests use committed JSON in `Tests/Fixtures/` only.

## What a job stores

Each planned section is decoded with extra audio on both sides of its owned `[start, end)` range so a word cut at a boundary is heard whole at least once. Overlap never shifts timestamps: engine results are already on the source timeline.

The checkpoint for a recording (`<Application Support>/Wordy/Transcripts/<sha256>.json`) keeps two lists per committed section:

| Field | Meaning |
| --- | --- |
| `raw` | Exactly what that section's engine returned (`RawSegment` start/end/text), after absolute-time shift. Older documents omit this. |
| `segments` | Captions after stitch. These are what the player, search, and export use. |

`TranscriptionCoordinator` writes `raw: result.segments` for both the XPC worker and OpenRouter. A fixture is that checkpoint, not a second transcription of the same windows. `CaptionJobFixture(name:checkpoint:)` copies policy, duration, `raw`, and committed captions. Hand-written JSON must use the same schema (`Core/CaptionJobFixture.swift`). Do not add a Python/OpenRouter/ffmpeg helper that re-implements `ChunkPlanner` or the decoder.

## Fold

```text
plan + raw-by-chunk  →  CaptionPipeline.reconcile  →  committed captions
```

Chunks do not drop phrases by owned time. `CaptionPipeline` feeds each section's `raw` list to `ChunkReconciler` in order; only the suffix/prefix stitch may remove overlap re-hears.

## Isolation: three word bags

Compare these, in order. Do not treat “gold minus committed” as a single failure.

1. **Gold − raw union** — the engine never returned the word in any section. That is a chunk window (planner) or ASR miss. The stitch cannot invent it.
2. **Unique raw − committed** — some section heard the word, but the stitch dropped it. That is a reconciler bug. Do not filter by owned start; trailing-overlap phrases are offered to the stitch too.
3. **Time-contained re-hears** — a raw interval whose end is still inside already-committed time is skipped as a timestamp duplicate. Distinct text that *starts* after the previous caption, including past the owned end, is kept for the stitch.

A time window that takes *every* word from any segment that merely overlaps the window will also count later words in a long Whisper phrase. That produced phantom “reconciler drops” of common tokens (`is`, `the`, `tang`) and is not a valid stitch check.

Committed functional tests (`Tests/CaptionPipelineTests.swift`) load every `Tests/Fixtures/*.json` and fold it through `CaptionPipeline`. The development clip lives in `Tests/Fixtures/clip-14-20/` (gold one-shot plus cloud 60 s+10 s `raw` recorded through `CaptionJobRecorder` / `OpenRouterSectionClient`). Gold is compared only as “never heard”; the hard stitch gate is unique heard words surviving. Re-record with `WORDY_RECORD_CLIP=1` (OpenRouter key in `.env`); default `make test-core` does not upload.

Do not point tests at `assets/`, environment paths, or live provider calls. Those confuse the next reader into thinking caption quality is validated outside the app. The private clip file may exist under git-ignored `assets/` for that opt-in re-record only.

## Overlap word budget

Spoken English is treated as about **1.25 words per second**. The stitch may drop at most that many leading words when a section re-hears already-committed time:

| Overlap | Budget |
| --- | --- |
| 3 s (local default) | 4 words |
| 5 s | 6 words |
| 10 s (cloud default) | 13 words |

`ChunkPolicy.boundaryWordBudget` implements the rounding. Each `AudioChunk` sizes the budget from its **leading** overlap (`ownedStart − audioStart`), so the first section (no lead-in) does not strip the start of the lecture.

Algorithm, only when an incoming raw interval starts before the previous caption's end:

1. Normalize words (lowercase, strip punctuation).
2. Find the longest suffix of the previous caption that equals a prefix of the incoming text (the full shared phrase, not a budget-capped search).
3. Drop `min(match, budget)` leading words.
4. Clamp the remaining caption's start to the previous end.

Time overlap alone never deletes distinct words. Deliberate repetition that starts after committed time is kept. Phrase captions remain the source of truth; word timing is not used.

## Policies in force

| Job | Owned stride | Overlap | Decoded peak |
| --- | --- | --- | --- |
| Local | 60 s | 3 s | 66 s |
| Cloud | 60 s | 10 s | 80 s (PCM WAV cap) |

Cloud keeps the 60 s stride so seams are not denser than OpenRouter Whisper's ~30 s phrase grid, and uses 10 s of lead-in so a phrase that starts on a boundary is still heard whole. A short tail still merges (`min(chunk/4, 10 s)`).

## Approaches tried

Recorded so the same experiments are not repeated without new evidence.

### Midpoint attribution

A segment was committed by the chunk that owned its midpoint. A sentence that started just before a boundary and ended just after it was discarded by both neighbors. Replaced by start-based attribution (below), then by offering every well-formed raw interval to the stitch. `docs/benchmarks/2026-09-13-m4max.md` measured the first recovery on local 60 s + 3 s.

### Fixed 8-word cap

The first start-based stitch dropped at most eight duplicated boundary words, independent of overlap seconds. Too small for cloud 10 s phrases and unrelated to the decoded overlap. Replaced by the overlap-derived budget above.

### Owned-end start filter

After midpoint attribution was dropped, a raw phrase was still discarded when its *start* sat on or past the chunk's owned end. Phrases heard only in trailing overlap (and missed by the next chunk's ASR grid) never reached the stitch. Removed: every well-formed raw interval is offered; only the suffix/prefix budget and time-contained skip may cut.

### Time-proportional deletion

When the two sides of a seam disagreed, the incoming caption was shortened in proportion to how much of its interval sat inside already-committed time. Distinct formula lists and whole clauses disappeared. Removed. Disagreeing text in overlapping time is kept; only the start timestamp is clamped.

### Aggressive mid-string dedupe

Matching and deleting repeated phrases anywhere in the incoming caption (not only a leading prefix vs a trailing suffix) dropped later sentences that happened to reuse short words. Reverted to prefix/suffix only.

### Search limited to the budget

The longest-match loop was capped at the budget (4 words at 3 s). A 5-word re-hear such as “as h goes to zero” has no matching suffix of length 1–4 (`h goes to zero` ≠ `as h goes to`), so the stitch dropped **nothing** and kept all five duplicates. The search is now unbounded; the budget only caps how many words are removed. At 3 s a 5-word match still drops four words and leaves one leftover duplicate — that is the approximation, not a miss of the whole phrase.

### Separate OpenRouter capture script

A Python helper uploaded the same clip as planned chunks and wrote fixture JSON. That duplicated the decoder, policy, and time shift, and drifted from the app. Removed, along with the git-ignored dumps it produced under `assets/asr-compare/`. Fixtures are `CaptionJobFixture` JSON committed in `Tests/Fixtures/`, produced from `TranscriptCheckpoint` or written against those types. Re-recording the development clip uses `CaptionJobRecorder` / `WORDY_RECORD_CLIP=1`, not a side script.

### Cloud 50 s + 15 s

Tried so each upload still fit the 80 s / 3 MiB PCM cap while adding lead-in. Extra seams landed in mid-sentence formula lists (herb names around 3:20 on a consented clip). The owning chunk's start filter then dropped phrases that began just past the owned end, and the next chunk transcribed a different ~30 s grid. Rejected in favor of **60 s + 10 s**.

### Dual reconcilers

Cloud briefly had extra phrase-merge / last-segment replacement rules (`CloudCaptionReconciler`, `replacingLastSegment`). They concatenated overlapping Whisper phrases into word salad or erased later clauses via short matches. Removed. Local and cloud jobs both call `ChunkReconciler.commit` and do not rewrite the previous caption.

### Gold-vs-committed as a single assertion

Comparing an unchunked one-shot transcript to stitched captions in one window mixed ASR misses, grid alignment, and stitch. Split into the three bags above. Remaining gold words on the sample clip that never appear in any chunk `raw` are engine/window issues, not proof that local transcription is broken.

## What still fails on purpose

- ASR will omit or respell terms the stitch never sees. Isolation should print those gold−raw gaps, not fail the stitch suite.
- A leftover duplicate of one or two words at a 3 s seam is expected when the true overlap is longer than the budget.
- `initial_prompt` / decoder context across chunks is still off.

## Code map

| Piece | Role |
| --- | --- |
| `Core/ChunkPlan.swift` | Policy, owned vs decoded ranges, `boundaryWordBudget` |
| `Core/ChunkReconciler.swift` | `RawSegment`, suffix/prefix stitch; all well-formed raw is offered |
| `Core/CaptionPipeline.swift` | Fold for tests and comparison |
| `Core/CaptionJobFixture.swift` | Checkpoint snapshot / committed JSON schema |
| `Core/TranscriptCheckpoint.swift` | Optional `raw: [[RawSegment]]` beside `segments` |
| `Core/CaptionJobRecorder` | Plans sections and records per-chunk `raw` through the same OpenRouter client as jobs |
| `Tests/Fixtures/` | Synthetic `CaptionJobFixture` JSON for `make test-core` |
| `Tests/Fixtures/clip-14-20/` | Gold one-shot plus cloud 60 s+10 s raw for the development clip |
| `Services/TranscriptionCoordinator.swift` | Persists engine raw on every local and cloud commit |
