import Foundation

/// Identity of the engine configuration used for one transcript generation.
/// Any change means results are not comparable and a new generation starts.
public struct TranscriptionConfiguration: Codable, Hashable, Sendable {
    public let engineName: String
    public let engineVersion: String
    public let modelID: String
    public let language: String
    public let policy: ChunkPolicy

    public init(engineName: String, engineVersion: String, modelID: String, language: String, policy: ChunkPolicy) {
        self.engineName = engineName
        self.engineVersion = engineVersion
        self.modelID = modelID
        self.language = language
        self.policy = policy
    }
}

/// Durable record of committed transcript work for one recording, keyed by the
/// recording's audio-content SHA-256. Chunks are committed in order, so the
/// checkpoint only needs the count of committed chunks. Milestone 1 stores this
/// as an atomically replaced JSON document; Milestone 2 moves it into GRDB with
/// the same invariants.
public struct TranscriptCheckpoint: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public enum CheckpointError: Error, Equatable {
        case unsupportedFormat(Int)
        case chunkOutOfOrder(expected: Int, received: Int)
        case invalidSegments
    }

    public let format: Int
    public let audioSHA256: String
    public let sourceDuration: TimeInterval
    public let configuration: TranscriptionConfiguration
    public let chunkCount: Int
    public private(set) var committedChunkCount: Int
    public private(set) var segments: [TranscriptSegment]
    public private(set) var detectedLanguage: String?
    public private(set) var updatedAt: Date

    public init(audioSHA256: String, sourceDuration: TimeInterval, configuration: TranscriptionConfiguration,
                chunkCount: Int, now: Date = Date())
    {
        format = Self.currentFormat
        self.audioSHA256 = audioSHA256
        self.sourceDuration = sourceDuration
        self.configuration = configuration
        self.chunkCount = chunkCount
        committedChunkCount = 0
        segments = []
        detectedLanguage = nil
        updatedAt = now
    }

    public var isComplete: Bool { committedChunkCount >= chunkCount }
    public var nextChunkIndex: Int? { isComplete ? nil : committedChunkCount }

    /// Source time through which results are final.
    public func completedThrough(plan: [AudioChunk]) -> TimeInterval {
        guard committedChunkCount > 0, committedChunkCount <= plan.count else { return isComplete ? sourceDuration : 0 }
        return plan[committedChunkCount - 1].ownedEnd
    }

    public func matches(audioSHA256: String, sourceDuration: TimeInterval, configuration: TranscriptionConfiguration,
                        chunkCount: Int) -> Bool
    {
        format == Self.currentFormat && self.audioSHA256 == audioSHA256
            && abs(self.sourceDuration - sourceDuration) < 0.05
            && self.configuration == configuration && self.chunkCount == chunkCount
    }

    /// Appends one chunk's committed segments. Callers persist the returned value
    /// before requesting the next chunk so a crash recomputes at most one chunk.
    public func committing(chunkIndex: Int, segments newSegments: [TranscriptSegment], detectedLanguage: String?,
                           now: Date = Date()) throws -> TranscriptCheckpoint
    {
        guard chunkIndex == committedChunkCount else {
            throw CheckpointError.chunkOutOfOrder(expected: committedChunkCount, received: chunkIndex)
        }
        let merged = segments + newSegments
        _ = try TranscriptTimeline(segments: merged)
        var next = self
        next.segments = merged
        next.committedChunkCount += 1
        next.updatedAt = now
        if next.detectedLanguage == nil {
            next.detectedLanguage = detectedLanguage
        }
        return next
    }

    public func validate() throws {
        guard format == Self.currentFormat else { throw CheckpointError.unsupportedFormat(format) }
        guard committedChunkCount >= 0, committedChunkCount <= chunkCount else { throw CheckpointError.invalidSegments }
        do { _ = try TranscriptTimeline(segments: segments) } catch { throw CheckpointError.invalidSegments }
    }
}
