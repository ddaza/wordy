import Foundation

/// Committed snapshot of one caption job: planner inputs plus per-section engine
/// `raw`. Build it from a `TranscriptCheckpoint` after a real local or cloud job,
/// or write synthetic JSON that uses the same schema. Tests fold it through
/// `CaptionPipeline`; do not capture the same windows with a side script.
public struct CaptionJobFixture: Codable, Equatable, Sendable {
    public struct TimedText: Codable, Equatable, Sendable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var text: String

        public init(start: TimeInterval, end: TimeInterval, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }

        public var raw: RawSegment {
            .init(start: start, end: end, text: text)
        }

        public var caption: TranscriptSegment {
            .init(start: start, end: end, text: text)
        }
    }

    public struct Chunk: Codable, Equatable, Sendable {
        public var index: Int
        public var raw: [TimedText]

        public init(index: Int, raw: [TimedText]) {
            self.index = index
            self.raw = raw
        }
    }

    public var name: String
    public var duration: TimeInterval
    public var policy: ChunkPolicy
    public var chunks: [Chunk]
    /// Intended captions after stitch. Word coverage must survive `reconcile()`.
    public var expected: [TimedText]

    public init(name: String, duration: TimeInterval, policy: ChunkPolicy, chunks: [Chunk],
                expected: [TimedText])
    {
        self.name = name
        self.duration = duration
        self.policy = policy
        self.chunks = chunks
        self.expected = expected
    }

    /// Snapshot a completed (or partial) checkpoint produced by the coordinator.
    public init(name: String, checkpoint: TranscriptCheckpoint) throws {
        let raw = checkpoint.raw ?? []
        guard raw.count == checkpoint.committedChunkCount else {
            throw CaptionJobFixtureError.rawMissing
        }
        self.name = name
        duration = checkpoint.sourceDuration
        policy = checkpoint.configuration.policy
        chunks = raw.enumerated().map { index, segments in
            Chunk(index: index, raw: segments.map { TimedText(start: $0.start, end: $0.end, text: $0.text) })
        }
        expected = checkpoint.segments.map { TimedText(start: $0.start, end: $0.end, text: $0.text) }
    }

    public var plan: [AudioChunk] {
        ChunkPlanner.plan(duration: duration, policy: policy)
    }

    public var rawByChunk: [[RawSegment]] {
        chunks.sorted { $0.index < $1.index }.map { $0.raw.map(\.raw) }
    }

    public func reconcile() -> [TranscriptSegment] {
        CaptionPipeline.reconcile(plan: plan, rawByChunk: rawByChunk)
    }
}

public enum CaptionJobFixtureError: Error, Equatable {
    case rawMissing
    case fixtureDirectoryMissing
}

public extension CaptionJobFixture {
    /// Words the owning chunk heard that the stitch dropped, expected words
    /// that never appear, and committed words that were not expected.
    func isolation() -> (ownedDropped: [String], expectedMissing: [String], unexpected: [String]) {
        let committed = reconcile()
        let committedWords = TranscriptCoverage.words(in: committed)
        var ownedDropped: [String] = []
        for (chunk, heard) in zip(plan, rawByChunk) {
            let owned = heard.filter { $0.start >= chunk.ownedStart && $0.start < chunk.ownedEnd }
            ownedDropped += TranscriptCoverage.missing(
                expected: TranscriptCoverage.words(in: owned), actual: committedWords,
            )
        }
        let expectedWords = TranscriptCoverage.words(in: expected.map(\.caption))
        let expectedMissing = TranscriptCoverage.missing(expected: expectedWords, actual: committedWords)
        let unexpected = TranscriptCoverage.missing(expected: committedWords, actual: expectedWords)
        return (ownedDropped, expectedMissing, unexpected)
    }
}
