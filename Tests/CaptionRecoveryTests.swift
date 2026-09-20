import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import WordyCore
#endif

struct CaptionRecoveryTests {
    private let configuration = OpenRouterModel.whisperLargeV3.configuration

    private func checkpoint() -> TranscriptCheckpoint {
        .init(audioSHA256: "synthetic", sourceDuration: 120, configuration: configuration, chunkCount: 2)
    }

    @Test(arguments: ["whisper.cpp", "OpenRouter"])
    func `both engines retain distinct contained speech through checkpoint commits`(engine: String) throws {
        let configuration = TranscriptionConfiguration(engineName: engine, engineVersion: "fixture",
                                                       modelID: "fixture", language: "en",
                                                       policy: engine == "OpenRouter" ? .cloudDefault : .default)
        var checkpoint = TranscriptCheckpoint(audioSHA256: "synthetic", sourceDuration: 120,
                                              configuration: configuration, chunkCount: 2)
        checkpoint = try checkpoint.committing(chunkIndex: 0,
                                               raw: [.init(start: 40, end: 63, text: "First source phrase.")],
                                               detectedLanguage: "en")
        checkpoint = try checkpoint.committing(chunkIndex: 1,
                                               raw: [.init(start: 58, end: 62, text: "Distinct contained phrase.")],
                                               detectedLanguage: "en")
        #expect(checkpoint.segments.map(\.text) == ["First source phrase.", "Distinct contained phrase."])
        #expect(checkpoint.segments.map(\.start) == [40, 58])
        #expect(checkpoint.segments.map(\.end) == [63, 62])
        #expect(checkpoint.isComplete && checkpoint.hasReplayableRaw)
        #expect((checkpoint.cloudUsage != nil) == (engine == "OpenRouter"))
    }

    @Test func `contained novel phrases retain their source interval and remain searchable`() throws {
        let plan = ChunkPlanner.plan(duration: 120, policy: .cloudDefault)
        let first = RawSegment(start: 40, end: 70, text: "Review the first example.")
        let second = RawSegment(start: 52, end: 62, text: "Now consider the second example.")
        let captions = CaptionPipeline.reconcile(plan: plan, rawByChunk: [[first], [second]])
        #expect(captions.map(\.text) == [first.text, second.text])
        #expect(captions.map(\.start) == [40, 52])
        #expect(captions.map(\.end) == [70, 62])
        #expect(captions[1].timingUncertain == true)
        let timeline = try TranscriptTimeline(segments: captions)
        #expect(timeline.activeSegments(at: 55).map(\.text) == [first.text, second.text])
        #expect(timeline.activeSegment(at: 62)?.text == first.text)
        #expect(timeline.activeSegments(at: 70).isEmpty)
        #expect(TranscriptSearch.hits(in: captions, query: "second example").first?.time == 52)
        #expect(TranscriptSearch.hits(in: captions, query: "example. Now").isEmpty)
    }

    @Test func `matching context spans several prior phrases but is consumed only once`() {
        let plan = ChunkPlanner.plan(duration: 120, policy: .cloudDefault)
        let captions = CaptionPipeline.reconcile(plan: plan, rawByChunk: [
            [.init(start: 50, end: 58, text: "We measure the rate"),
             .init(start: 58, end: 68, text: "of change over time.")],
            [.init(start: 52, end: 70, text: "the rate of change over time. First application."),
             .init(start: 72, end: 75, text: "of change over time.")],
        ])
        #expect(captions.map(\.text) == ["We measure the rate", "of change over time.",
                                         "First application.", "of change over time."])
        #expect(captions.map(\.start) == [50, 58, 68, 72])
    }

    @Test func `one previous occurrence cannot erase two intentional repetitions`() {
        let plan = ChunkPlanner.plan(duration: 120, policy: .cloudDefault)
        let captions = CaptionPipeline.reconcile(plan: plan, rawByChunk: [
            [.init(start: 50, end: 70, text: "Please repeat this sentence.")],
            [.init(start: 52, end: 60, text: "Please repeat this sentence."),
             .init(start: 62, end: 68, text: "Please repeat this sentence.")],
        ])
        #expect(captions.map(\.text) == ["Please repeat this sentence.", "Please repeat this sentence."])
        #expect(captions.map(\.start) == [50, 62])
    }

    @Test func `a matching prefix uses its own phrase end rather than an unrelated overlap end`() {
        let plan = ChunkPlanner.plan(duration: 120, policy: .cloudDefault)
        let captions = CaptionPipeline.reconcile(plan: plan, rawByChunk: [
            [.init(start: 50, end: 70, text: "An unrelated long phrase."),
             .init(start: 55, end: 63, text: "boundary anchor here")],
            [.init(start: 58, end: 68, text: "boundary anchor here distinct ending")],
        ])
        #expect(captions.map(\.text) == ["An unrelated long phrase.", "boundary anchor here", "distinct ending"])
        #expect(captions.last?.start == 63 && captions.last?.end == 68)
    }

    @Test func `punctuation and parenthesized speech do not delete spoken words`() {
        let plan = ChunkPlanner.plan(duration: 120, policy: .cloudDefault)
        let captions = CaptionPipeline.reconcile(plan: plan, rawByChunk: [
            [.init(start: 50, end: 65, text: "alpha beta gamma")],
            [.init(start: 58, end: 70, text: "alpha — beta gamma distinct ending"),
             .init(start: 75, end: 80, text: "(This is spoken lecture content.)"),
             .init(start: 81, end: 83, text: "[BLANK_AUDIO]")],
        ])
        #expect(captions.map(\.text) == ["alpha beta gamma", "distinct ending", "(This is spoken lecture content.)"])
        #expect(captions.map(\.start) == [50, 65, 75])
    }

    @Test func `provisional boundary survives save and resume and EOF flushes it`() throws {
        let raw = [RawSegment(start: 40, end: 70, text: "First example.")]
        let first = try checkpoint().committing(chunkIndex: 0, raw: raw, detectedLanguage: "en")
        #expect(first.segments.isEmpty)
        #expect(first.pendingSegments?.map(\.text) == ["First example."])
        #expect(first.completedThrough(plan: ChunkPlanner.plan(duration: 120, policy: .cloudDefault)) == 40)
        let restored = try JSONDecoder().decode(TranscriptCheckpoint.self, from: JSONEncoder().encode(first))
        let second = try restored.committing(chunkIndex: 1,
                                             raw: [.init(start: 55, end: 65, text: "Distinct explanation.")],
                                             detectedLanguage: nil)
        #expect(second.isComplete && second.pendingSegments?.isEmpty == true)
        #expect(second.segments.map(\.text) == ["First example.", "Distinct explanation."])
        #expect(second.segments.first?.id == first.pendingSegments?.first?.id)
        #expect(second.raw?.count == 2 && second.hasReplayableRaw)
        #expect(second.cloudUsage?.sections == 2)
        try second.validate()
    }

    @Test func `repair restores lost phrases once without changing identity progress or billing`() throws {
        let first = TranscriptSegment(start: 40, end: 70, text: "First example.")
        var legacy = try checkpoint().committing(chunkIndex: 0, segments: [first], detectedLanguage: "en",
                                                 raw: [.init(start: 40, end: 70, text: first.text)])
        legacy = try legacy.committing(chunkIndex: 1, segments: [], detectedLanguage: nil,
                                       raw: [.init(start: 55, end: 65, text: "Distinct explanation.")])
        let repaired = try legacy.repairingCaptions()
        #expect(repaired.segments.map(\.text) == [first.text, "Distinct explanation."])
        #expect(repaired.segments.first?.id == first.id)
        #expect(repaired.segments.last?.start == 55)
        #expect(repaired.audioSHA256 == legacy.audioSHA256 && repaired.configuration == legacy.configuration)
        #expect(repaired.committedChunkCount == legacy.committedChunkCount && repaired.isComplete)
        #expect(repaired.updatedAt == legacy.updatedAt && repaired.cloudUsage == legacy.cloudUsage)
        #expect(repaired.raw == legacy.raw && repaired.detectedLanguage == legacy.detectedLanguage)
        #expect(try repaired.repairingCaptions() == repaired)
    }

    @Test func `missing raw and ambiguous legacy empty lists never erase saved captions`() throws {
        let saved = TranscriptSegment(start: 0, end: 10, text: "Saved work.")
        let partial = try checkpoint().committing(chunkIndex: 0, segments: [saved], detectedLanguage: nil)
        #expect(!partial.hasReplayableRaw)
        #expect(try partial.repairingCaptions() == partial)
        var document = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(partial)) as? [String: Any])
        document.removeValue(forKey: "rawIsComplete")
        let legacy = try JSONDecoder().decode(TranscriptCheckpoint.self, from: JSONSerialization.data(withJSONObject: document))
        #expect(!legacy.hasReplayableRaw)
        #expect(try legacy.repairingCaptions() == legacy)
        document.removeValue(forKey: "raw")
        let missing = try JSONDecoder().decode(TranscriptCheckpoint.self, from: JSONSerialization.data(withJSONObject: document))
        #expect(try missing.repairingCaptions() == missing)
        let resumed = try missing.committing(chunkIndex: 1, raw: [], detectedLanguage: nil)
        #expect(resumed.segments == [saved] && !resumed.hasReplayableRaw)
    }

    @Test func `long jobs keep only a bounded boundary and preserve finalized IDs`() throws {
        let plan = ChunkPlanner.plan(duration: 7200, policy: .cloudDefault)
        var state = CaptionPipeline.State()
        var firstID: UUID?
        for (index, chunk) in plan.enumerated() {
            state.append(raw: [.init(start: chunk.audioStart, end: chunk.audioEnd, text: "Unique passage number \(index).")],
                         chunk: chunk, next: index + 1 < plan.count ? plan[index + 1] : nil)
            #expect(state.pending.count <= 2)
            if let firstID {
                #expect(state.committed.first?.id == firstID)
            } else {
                firstID = state.committed.first?.id
            }
        }
        #expect(state.pending.isEmpty && state.committed.count == plan.count)
        _ = try TranscriptTimeline(segments: state.committed)
    }

    @Test func `known silence is replayable but malformed raw cannot replace saved work`() throws {
        var silence = try checkpoint().committing(chunkIndex: 0, raw: [], detectedLanguage: nil)
        silence = try silence.committing(chunkIndex: 1, raw: [], detectedLanguage: nil)
        #expect(silence.hasReplayableRaw && silence.isComplete && silence.segments.isEmpty)
        var document = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(silence)) as? [String: Any])
        document.removeValue(forKey: "captionRevision")
        let older = try JSONDecoder().decode(TranscriptCheckpoint.self, from: JSONSerialization.data(withJSONObject: document))
        #expect(try older.repairingCaptions().captionRevision == ChunkReconciler.revision)

        let saved = TranscriptSegment(start: 0, end: 10, text: "Saved work.")
        let invalidRaw = [RawSegment(start: 2, end: 1000, text: "Malformed timing.")]
        let malformed = try checkpoint().committing(chunkIndex: 0, segments: [saved], detectedLanguage: nil, raw: invalidRaw)
        #expect(try malformed.repairingCaptions() == malformed)
        #expect(throws: TranscriptCheckpoint.CheckpointError.invalidSegments) {
            try checkpoint().committing(chunkIndex: 0, raw: invalidRaw, detectedLanguage: nil)
        }
    }
}
