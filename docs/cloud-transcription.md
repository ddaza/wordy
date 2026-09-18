# Advanced Mode: OpenRouter transcription

Implemented ahead of the remaining Milestone 2 work by user request on 2026-09-17. Local whisper.cpp remains the default. This adds no backend, dependency, telemetry, or automatic fallback.

## Using it

1. Open Wordy → Settings, enable **Advanced Mode**, and save your OpenRouter API key. It is stored only in the macOS Keychain. Enabling the setting does not upload anything.
2. Advanced Mode appears near the top of Settings. After the green **API key saved in Keychain** confirmation, click **Use** beside **Whisper Large V3** or **Whisper Large V3 Turbo**. Use is disabled until the key is saved. The model marked **In use** is the selection for new jobs and Transcribe Again. No local model download is needed for a cloud job.
3. Import/open a recording, choose **Transcribe with OpenRouter…**, review its name, duration, model, upload disclosure, and billing/cancellation terms, then choose **Upload and Transcribe**.
4. **Pause** stops further uploads. **Resume with OpenRouter…** asks again before continuing. Resume uses the unfinished job’s original model. **Transcribe Again…** starts a new generation with the model currently marked **In use**, including a newly chosen cloud model. Its confirmation snapshots and names that model; cloud jobs still require upload consent. The recording header shows both the selected model and the model used by the recording’s current job/transcript. Selecting a local model with Use switches new jobs back to local.

Cloud usage is billed to the user's OpenRouter account. The confirmation links to current model pricing and providers; Wordy does not promise a fixed price or proxy billing. A provider may complete and charge for an accepted request after Wordy cancels it. Manual retry of an uncertain section may repeat that charge.

## Data flow and bounds

`CloudSettings` stores the enabled flag, model ID, and explicit cloud-selection preference in UserDefaults. Keychain operations run on an actor; the secure field is cleared after a successful save. Removing the key or disabling Advanced Mode invalidates outstanding consent and cancels queued/active cloud jobs. Reading a saved key never starts a job.

The coordinator serializes local and cloud work in the same queue. A one-use consent snapshot binds the recording ID, SHA-256, display name, duration, and model. Re-imported cloud checkpoints are always paused unless already complete. Generic Resume, model installation, launch, and local failures cannot authorize a cloud request.

`OpenRouterProvider` uses the shared AVFoundation decoder (moved from `Inference/` to `Core/`) on an actor, retaining the first decoded presentation timestamp. Cloud sections use `ChunkPolicy.cloudDefault` (**50 s owned + 15 s overlap**, decoded window ≤ 80 s). The local default remains 60 s + 3 s. The wider cloud overlap exists because OpenRouter Whisper returns coarse ~30 s phrases: with only 3 s of context, phrases that start on an owned boundary are dropped by the previous section and often resume mid-sentence in the next, deleting titles and clauses. The short-tail rule still keeps decoded sections under 80 seconds. Each upload is 16 kHz mono 16-bit PCM WAV, under 3 MiB, with the generic filename `section.wav`. The complete lecture is never loaded into memory or uploaded in a single request, and temporary WAV files are not written to disk. The initial incremental SHA-256 check and per-section file metadata checks reject changed sources.

Requests use the fixed HTTPS `/api/v1/audio/transcriptions` endpoint, multipart `file`, `model`, `response_format=verbose_json`, and `timestamp_granularities[]=segment`. The URLSession is ephemeral, disables cache/cookies, refuses redirects, and has a 120-second resource timeout. There are no application-level automatic HTTP retries. Responses are limited to 2 MiB and 4,096 segments. No provider response body, API key, audio, transcript, or source filename is logged.

Only usable segment timestamps are accepted; Wordy does not fabricate timings from plain text. Explicitly empty segment/text output represents silence. Malformed, missing, reversed, unordered, or substantially out-of-range timing fails the section. Relative times are shifted by the actual decoded source offset. `CloudCaptionReconciler` clamps overlapping phrases to the prior end and drops leading words only on an exact boundary match (never by time proportion, and never by shortening the previous caption). That avoids the gaps/duplicates seen when provider phrase times nest or partially overlap.

## Cloud usage in the transcription status

After each section completes, the status shows the reported cost in USD, total/input/output tokens when provided, and the last section's observed cost per audio hour. Cloud speed includes audio preparation and the request/response time. There is also a link to the model's current published pricing. The observed rate is computed only from `usage.cost` and `usage.seconds`; it is not a promised rate for future requests. No guessed token counts or hard-coded prices are shown.

Usage totals are committed atomically with the section and restored on resume/re-import, so completed sections are not counted twice. Missing fields are shown as **Not reported** or **partial**, not zero. Existing checkpoints without usage remain readable and their earlier sections have unknown usage. These figures cover saved sections of the current transcript generation; failed/cancelled requests and replaced generations can incur additional charges, so this is not an account-wide bill.

## Persistence and failures

Completed sections use the existing digest-keyed, atomically written JSON checkpoint store. Configuration includes OpenRouter adapter version, exact model ID, language policy, and chunk policy. GRDB/FTS persistence remains Milestone 2. The app coordinates writes and publishes only committed sections.

When replacing a transcript, the previous document stays intact until the first replacement section is saved. A failure before that point preserves the old transcript. A resume skips committed matching sections, preserving their IDs. A successful response is committed before another upload is allowed. Disk-write failure stops the job rather than proceeding without a checkpoint.

401/403, insufficient credits, rate limits, server errors, invalid transcripts, oversized responses, and connection failures produce fixed actionable messages. No automatic retry occurs on network loss, timeout, sleep/wake, relaunch, or provider failure. User confirmation is required to resume/retry; uncertain uncommitted work may be billed again.

## Verification and remaining checks

Automated tests use generated WAV data, in-memory credentials, temporary checkpoints, a stub provider, and intercepted URLSession requests. No API key from the developer's Keychain or real lecture is used. Coverage includes consent/key/enable gating, one-use consent, model snapshotting, queue revocation, cancellation, failed replacement preservation, partial recovery, source changes, timestamp normalization, repetition, request formatting, authentication/quota/rate errors, network loss, and no automatic retries.

Verified on the development arm64 MacBook Pro, macOS 26.7 (2026-09-18): 33 SwiftPM core tests and 55 native Xcode tests passed with no failures. The Universal Release app and worker passed architecture, macOS 14 deployment-target, and nested ad-hoc signature verification. SwiftFormat lint and project property-list validation passed. These are functional/build checks, not performance measurements.

Before release, manually exercise Keychain save/update/remove and the consent sheet, then deliberately authorize a live short recording followed by a long cloud job. Check phrase timing, cost, pause/resume, quit/reopen, sleep/wake, interrupted connections, and concurrent playback/search. Physical Intel/M1 resource measurements and a live multi-hour cloud run are still outstanding. Mock HTTP tests are not live service validation.

API contract reviewed against [OpenRouter's STT guide](https://openrouter.ai/docs/guides/overview/multimodal/stt) and [transcription reference](https://openrouter.ai/docs/api/api-reference/stt/create-transcription). The model choices follow the existing private comparison summarized in `PLAN.md`; exact provider rates are not pinned. Deepgram and provider-specific vocabulary options remain excluded until validated.
