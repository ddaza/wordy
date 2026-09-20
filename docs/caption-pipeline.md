# Caption pipeline: source timing, overlap, and recovery

Local whisper.cpp and Advanced Mode share the same pipeline. Private audio remains under git-ignored `assets/`; no recording or transcript is uploaded by reconciliation or checkpoint repair.

## Revision 2: why the boundary changed

The previous append-only stitch skipped every raw interval ending inside already committed time, even when its text was distinct. For other overlaps it moved the incoming start to the previous end without requiring a text match. Replaying the recorded development fixture found five unchanged captions moved later, by up to 20 seconds. This measured a stitch error, not ground-truth model timing.

Word sets did not detect these errors: a missing repeated sentence can contain no unique words, and a word bag ignores phrase order and time. One old test explicitly expected a distinct contained phrase to disappear. Revision 2 replaces those expectations with source-time and ordered-phrase checks.

## Stored state and finalization

A checkpoint stores:

| Field | Meaning |
| --- | --- |
| `raw` | Per-section engine output on the absolute source timeline, unchanged |
| `rawIsComplete` | Whether every saved section has its actual raw response; an empty response can be known silence |
| `segments` | Finalized captions; text export uses this list |
| `pendingSegments` | Persisted, provisional overlap tail awaiting the next section |
| `captionRevision` | The reconciliation revision, independently of engine/model configuration |

Playback, the transcript list, and search publish `segments` plus that tail. The tail is labeled approximate until the next section finalizes it. `completedThrough` still stops before the unfinalized region so the remaining-work banner stays honest.

`CaptionPipeline.State` retains the tail that could overlap the next decoded window. It finalizes only the ordered prefix ending before the next audio start, with 250 ms of tolerance for decoded-frame rounding. This is not an owned-time filter: the withheld phrases remain in the checkpoint, are shown as approximate, are reconciled with the next response, and are flushed at end of file. A pause or failed following section keeps the raw results and pending tail without repeating completed inference or billed requests.

The coordinator runs reconciliation and persistence on `CheckpointStore`'s actor, then publishes. The benchmark harness and fixture fold use the same state machine. An unchanged finalized prefix retains its IDs.

## Text and timing rules

For each incoming phrase:

1. Look only at preceding-section captions intersecting its source interval. Do not deduplicate repetitions within one engine response.
2. Normalize whitespace-separated tokens while retaining their string positions, so punctuation cannot make token counting disagree with text deletion.
3. Remove a complete incoming phrase only when its ordered tokens match contiguous previous tokens in that overlap. Require at least three tokens and two distinct words, or identical text and near-identical interval bounds for a short phrase.
4. Otherwise match only the incoming prefix against the previous suffix, potentially across several previous captions. Require the same three-token/two-distinct-word minimum. Remove the full match, without a words-per-second budget.
5. Consume each matched previous token at most once per incoming section. One previous occurrence cannot erase two repeated incoming sentences.
6. A removed prefix may use the matching preceding phrase's end as the remaining caption's start, only if a positive interval remains. Mark this timing approximate. If there is no interval left, preserve the whole incoming phrase.
7. Without matching text, retain the complete phrase at its source start and end. Never delete it because it is contained in another interval, and never move it after the preceding caption.

Known whole nonspeech markers are suppressed. Ordinary parenthesized speech is preserved. Ends that only overshoot the decoded window by the 250 ms slack are clamped; phrases farther outside that window are dropped from the stitch without failing the section. Stored raw stays the original engine list. Wild timing in a legacy checkpoint still blocks automatic repair so saved captions are not replaced with silence.

## Ambiguous intervals are explicit

Coarse phrase timestamps do not tell us exactly when an unmatched clause was spoken. Distinct overlapping captions remain separate records with `timingUncertain`, rather than concatenating competing versions into one sentence or fabricating word times.

The timeline accepts overlaps only when they are explicitly marked, indexes interval ends as well as starts, and returns all active phrases. Playback shows those phrases separately with an approximate-timing label; transcript rows highlight together. After a contained phrase ends, the longer active phrase is still shown. If a stitch omits the overlap flag, playback marks it for display rather than clearing every caption. Gaps, half-open endpoints, seeks, and EOF use the media clock.

Search retains each phrase's original playable start. It does not create cross-phrase matches by concatenating conflicting overlapping alternatives. Normal adjacent captions still support cross-boundary phrase search.

Conservative matching can retain duplicate wording when two ASR windows paraphrase each other or share only a short/common expression. The UI labels the uncertain timing; the pipeline does not claim to choose which alternative is acoustically correct. Word alignment or a reviewed audio reference would be needed to resolve that ambiguity reliably.

## Repairing existing checkpoints

Loading a checkpoint with an older caption revision replays its saved raw responses locally when that history is complete and valid. Before replacement, the store writes the original bytes to `<sha256>.before-caption-v2.json` beside the checkpoint. The repaired document is written atomically. The backup is retained and never overwritten by another load.

Repair preserves the recording digest, configuration, language, completed section count, recorded usage/cost, and timestamps of completed work. Unchanged captions retain their IDs. It is idempotent, does not run ASR, and does not upload audio. Completed cloud jobs stay complete; partial cloud jobs stay paused and still require fresh consent to resume.

Older documents may have omitted raw data or padded unavailable sections with empty lists. Without an explicit completeness flag, an empty legacy list is ambiguous and disables automatic repair. Such transcripts are left intact. A transcript without sufficient raw data needs a user-initiated retranscription to recover missing speech. Slightly rounded engine ends are clamped and repaired; wildly out-of-window raw still prevents repair. Storage failures stop restoration rather than starting over and overwriting saved work.

## Verification and isolation

- Synthetic JSON in `Tests/Fixtures/` specifies exact ordered phrases and start/end times. Tests compare these directly, including repetition counts.
- `CaptionRecoveryTests` covers contained phrases, multiple-caption anchors, one-to-one duplicate consumption, punctuation, known silence, pending-tail recovery, published approximate tails, per-phrase window sanitization, EOF, migration, billing preservation, and a synthetic two-hour fold.
- Native app tests cover automatic local repair and backup preservation, paused cloud restoration without uploads, and real AVPlayer seeks through overlapping intervals.
- `Tests/Fixtures/clip-14-20/` holds the existing recorded raw fixture. Its tests check phrase-local ordered coverage and ensure unchanged captions are never shifted. The global word-set check is only supplementary.
- Gold minus raw is an ASR/window miss, not a stitch omission. A one-shot ASR transcript is not a human-reviewed timing reference and does not establish accuracy against the audio.

A fixture comes from `CaptionJobFixture(name:checkpoint:)` or synthetic JSON using that schema. Partial fixtures retain the plan and replay only the completed prefix. Do not introduce a separate decoder/planner capture script. The opt-in `WORDY_RECORD_CLIP=1` recorder uses the real `OpenRouterSectionClient`; normal tests never upload.

## Policies and rejected approaches

Local remains 60 s owned + 3 s context; cloud remains 60 s + 10 s context (80 s maximum middle window). Short tails still merge. No model, provider, or audio chunk policy changed for this repair.

Keep these earlier failures in mind:

- Midpoint attribution and owned-end start filters discarded phrases heard only at a seam.
- Time-proportional deletion erased distinct clauses when two windows disagreed.
- Arbitrary mid-string/short-word matching erased text before the anchor.
- Fixed eight-word caps and later overlap-derived word budgets left partial duplicate phrases.
- Treating a time-contained phrase as a duplicate erased distinct speech.
- Concatenating competing cloud phrases obscured their separate timing and wording.
- A separate cloud recorder drifted from the application's decoder and planner.
- Cloud 50 s + 15 s added seams without establishing better recognition.
- Gold-versus-committed word bags mixed engine omissions with stitch errors and could not validate synchronization.

The revised boundary keeps uncertainty explicit. It does not recover words absent from every raw response, establish exact word timing, or replace long-recording listening and physical M1/Intel validation.
