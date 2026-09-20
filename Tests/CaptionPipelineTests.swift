import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import WordyCore
#endif

private enum CaptionFixtureStore {
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    static func loadAll() throws -> [CaptionJobFixture] {
        let directory = Self.directory
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
        #expect(!names.isEmpty, "committed caption fixtures must live in Tests/Fixtures")
        return try names.map { name in
            try JSONDecoder().decode(CaptionJobFixture.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
        }
    }
}

struct CaptionPipelineTests {
    @Test func `planner tiles duration and adds overlap without shifting owned time`() throws {
        let policy = try ChunkPolicy(chunkSeconds: 60, overlapSeconds: 10)
        let plan = ChunkPlanner.plan(duration: 360, policy: policy)
        #expect(plan.count == 6)
        #expect(plan.first?.ownedStart == 0)
        #expect(plan.last?.ownedEnd == 360)
        for (previous, next) in zip(plan, plan.dropFirst()) {
            #expect(previous.ownedEnd == next.ownedStart)
            #expect(next.audioStart == next.ownedStart - 10)
            #expect(previous.audioEnd == previous.ownedEnd + 10)
        }
        #expect(plan[3].ownedStart == 180)
        #expect(plan[3].ownedEnd == 240)
        #expect(plan[3].audioStart == 170)
        #expect(plan[3].audioEnd == 250)
    }

    @Test func `committed fixtures fold through CaptionPipeline`() throws {
        for fixture in try CaptionFixtureStore.loadAll() {
            let plan = fixture.plan
            #expect(plan.count == fixture.chunks.count, Comment(rawValue: fixture.name))
            #expect(plan.first?.ownedStart == 0)
            #expect(plan.last?.ownedEnd == fixture.duration)

            let committed = fixture.reconcile()
            _ = try TranscriptTimeline(segments: committed)
            let (heardDropped, expectedMissing, unexpected) = fixture.isolation()
            #expect(
                heardDropped.isEmpty,
                Comment(rawValue: "\(fixture.name) stitch dropped \(heardDropped.joined(separator: " "))"),
            )
            #expect(
                expectedMissing.isEmpty,
                Comment(rawValue: "\(fixture.name) missing expected \(expectedMissing.joined(separator: " "))"),
            )
            #expect(
                unexpected.isEmpty,
                Comment(rawValue: "\(fixture.name) unexpected \(unexpected.joined(separator: " "))"),
            )
        }
    }

    @Test func `checkpoint raw round trips through a caption fixture`() throws {
        let policy = ChunkPolicy.default
        let plan = ChunkPlanner.plan(duration: 120, policy: policy)
        let configuration = TranscriptionConfiguration(
            engineName: "whisper.cpp", engineVersion: "1.9.4", modelID: "whisper-small", language: "auto",
            policy: policy,
        )
        var checkpoint = TranscriptCheckpoint(
            audioSHA256: "fixture", sourceDuration: 120, configuration: configuration, chunkCount: plan.count,
        )
        let firstRaw = [RawSegment(start: 50, end: 62, text: "We define the limit as h goes to zero")]
        checkpoint = try checkpoint.committing(
            chunkIndex: 0,
            segments: ChunkReconciler.commit(raw: firstRaw, for: plan[0], after: []),
            detectedLanguage: "en",
            raw: firstRaw,
        )
        let secondRaw = [RawSegment(start: 60.5, end: 66, text: "as h goes to zero of the difference quotient.")]
        checkpoint = try checkpoint.committing(
            chunkIndex: 1,
            segments: ChunkReconciler.commit(raw: secondRaw, for: plan[1], after: checkpoint.segments),
            detectedLanguage: "en",
            raw: secondRaw,
        )

        let fixture = try CaptionJobFixture(name: "from-checkpoint", checkpoint: checkpoint)
        #expect(fixture.chunks.count == 2)
        #expect(fixture.rawByChunk[0].first?.text == firstRaw[0].text)
        let committed = fixture.reconcile()
        #expect(committed.map(\.text) == checkpoint.segments.map(\.text))
    }
}
