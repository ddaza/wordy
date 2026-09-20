# Caption pipeline: raw engine output and overlap stitch

This records how Wordy turns chunked ASR into committed captions, how to tell a planner/ASR miss from a stitch bug, and which alternatives were tried and rejected. Local whisper.cpp and Advanced Mode (OpenRouter) share the same stitch. See `docs/inference.md` for the worker and checkpoints, and `docs/cloud-transcription.md` for upload bounds and consent.

Private lecture audio stays under git-ignored `assets/` (and any local checkpoint dumps under `PrivateFixtures/`). Do not commit recordings, quote them, or upload them without the recording owner's authorization. Functional caption tests use committed synthetic JSON in `Tests/Fixtures/` only.

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

`CaptionPipeline` (`Core/CaptionPipeline.swift`) is a black-box fold over `ChunkReconciler.commit`. Tests and jobs pass recorded raw lists; the coordinator owns decoding, XPC, and HTTP. Local and cloud use the same rule. `CloudCaptionReconciler` is a thin wrapper so existing call sites keep compiling.

## Isolation: three word bags

Compare these, in order. Do not treat “gold minus committed” as a single failure.

1. **Gold − raw union** — the engine never returned the word in any section. That is a chunk window (planner) or ASR miss. The stitch cannot invent it.
2. **Owning-chunk raw − committed** — the section that owns the word's start heard it, but the stitch dropped it. That is a reconciler bug.
3. **Raw in a non-owning overlap − committed** — a trailing window heard speech whose start belongs to the next section, and the next section transcribed something else. Attribution is working as designed; the owning window did not hear those words.

A time window that takes *every* word from any segment that merely overlaps the window will also count later words in a long Whisper phrase. That produced phantom “reconciler drops” of common tokens (`is`, `the`, `tang`) and is not a valid stitch check.

Committed functional tests (`Tests/CaptionPipelineTests.swift`) load every `Tests/Fixtures/*.json` and fold it through `CaptionPipeline`. Each fixture must keep owning-chunk raw words and the `expected` captions. Add a new case by writing that JSON (or exporting a checkpoint from a Wordy job and replacing private text with synthetic wording). Unit checks for a single seam also live in `Tests/ChunkPipelineTests.swift`.

Do not point tests at `assets/`, environment paths, or live provider calls. Those confuse the next reader into thinking caption quality is validated outside the app.

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

A segment was committed by the chunk that owned its midpoint. A sentence that started just before a boundary and ended just after it was discarded by both neighbors. Replaced by **start-based** attribution: the chunk that heard the sentence *start* (with trailing overlap as right context) commits it. `docs/benchmarks/2026-09-13-m4max.md` measured the recovery on local 60 s + 3 s.

### Fixed 8-word cap

The first start-based stitch dropped at most eight duplicated boundary words, independent of overlap seconds. Too small for cloud 10 s phrases and unrelated to the decoded overlap. Replaced by the overlap-derived budget above.

### Time-proportional deletion

When the two sides of a seam disagreed, the incoming caption was shortened in proportion to how much of its interval sat inside already-committed time. Distinct formula lists and whole clauses disappeared. Removed. Disagreeing text in overlapping time is kept; only the start timestamp is clamped.

### Aggressive mid-string dedupe

Matching and deleting repeated phrases anywhere in the incoming caption (not only a leading prefix vs a trailing suffix) dropped later sentences that happened to reuse short words. Reverted to prefix/suffix only.

### Search limited to the budget

The longest-match loop was capped at the budget (4 words at 3 s). A 5-word re-hear such as “as h goes to zero” has no matching suffix of length 1–4 (`h goes to zero` ≠ `as h goes to`), so the stitch dropped **nothing** and kept all five duplicates. The search is now unbounded; the budget only caps how many words are removed. At 3 s a 5-word match still drops four words and leaves one leftover duplicate — that is the approximation, not a miss of the whole phrase.

### Separate OpenRouter capture script

A Python helper uploaded the same clip as planned chunks and wrote fixture JSON. That duplicated the decoder, policy, and time shift, and drifted from the app. Removed. Optional git-ignored dumps under `assets/asr-compare/` were the same idea and are not a test input. Fixtures are `CaptionJobFixture` JSON committed in `Tests/Fixtures/`, produced from `TranscriptCheckpoint` or written against those types.

### Cloud 50 s + 15 s

Tried so each upload still fit the 80 s / 3 MiB PCM cap while adding lead-in. Extra seams landed in mid-sentence formula lists (herb names around 3:20 on a consented clip). The owning chunk's start filter then dropped phrases that began just past the owned end, and the next chunk transcribed a different ~30 s grid. Rejected in favor of **60 s + 10 s**.

### Dual reconcilers

Cloud briefly had extra phrase-merge / last-segment replacement rules. They concatenated overlapping Whisper phrases into word salad or erased later clauses via short matches. Cloud now calls `ChunkReconciler.commit` and does not rewrite the previous caption.

### Gold-vs-committed as a single assertion

Comparing an unchunked one-shot transcript to stitched captions in one window mixed ASR misses, grid alignment, and stitch. Split into the three bags above. Remaining gold words on the sample clip that never appear in any chunk `raw` are engine/window issues, not proof that local transcription is broken.

## What still fails on purpose

- ASR will omit or respell terms the stitch never sees. Isolation should print those gold−raw gaps, not fail the stitch suite.
- A leftover duplicate of one or two words at a 3 s seam is expected when the true overlap is longer than the budget.
- A word heard only in the previous section's trailing overlap, whose start belongs to the next section that did not repeat it, is lost. Fixing that means changing the window or the engine, not deleting more text in the stitch.
- `initial_prompt` / decoder context across chunks is still off.

## Code map

| Piece | Role |
| --- | --- |
| `Core/ChunkPlan.swift` | Policy, owned vs decoded ranges, `boundaryWordBudget` |
| `Core/ChunkReconciler.swift` | `RawSegment`, start-based commit, suffix/prefix stitch |
| `Core/CloudCaptionReconciler.swift` | Same stitch; keeps the cloud call shape |
| `Core/CaptionPipeline.swift` | Fold for tests and comparison |
| `Core/CaptionJobFixture.swift` | Checkpoint snapshot / committed JSON schema |
| `Core/TranscriptCheckpoint.swift` | Optional `raw: [[RawSegment]]` beside `segments` |
| `Tests/Fixtures/` | Synthetic `CaptionJobFixture` JSON for `make test-core` |
| `Services/TranscriptionCoordinator.swift` | Persists engine raw on every local and cloud commit |
