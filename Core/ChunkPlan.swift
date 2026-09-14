import Foundation

/// Scheduling and checkpoint unit for long recordings. Chunks own a half-open
/// range of source time and decode extra context on both sides so words cut at
/// a boundary are heard whole by at least one chunk. Overlap never changes the
/// timeline: every result keeps absolute source timestamps.
public struct ChunkPolicy: Codable, Hashable, Sendable {
    public enum PolicyError: Error, Equatable { case invalidChunkLength, invalidOverlap }

    public let chunkSeconds: TimeInterval
    public let overlapSeconds: TimeInterval

    public init(chunkSeconds: TimeInterval, overlapSeconds: TimeInterval) throws {
        guard chunkSeconds.isFinite, chunkSeconds >= 5 else { throw PolicyError.invalidChunkLength }
        guard overlapSeconds.isFinite, overlapSeconds >= 0, overlapSeconds * 2 < chunkSeconds else {
            throw PolicyError.invalidOverlap
        }
        self.chunkSeconds = chunkSeconds
        self.overlapSeconds = overlapSeconds
    }

    /// Provisional default until the Milestone 1 benchmark settles the policy.
    public static let `default` = try! ChunkPolicy(chunkSeconds: 60, overlapSeconds: 3)

    public var label: String {
        "\(Int(chunkSeconds))s+\(Int(overlapSeconds))s"
    }
}

public struct AudioChunk: Codable, Hashable, Sendable, Identifiable {
    public let index: Int
    /// Source range whose results this chunk commits: [ownedStart, ownedEnd).
    public let ownedStart: TimeInterval
    public let ownedEnd: TimeInterval
    /// Source range decoded and sent to the engine, including overlap context.
    public let audioStart: TimeInterval
    public let audioEnd: TimeInterval

    public init(index: Int, ownedStart: TimeInterval, ownedEnd: TimeInterval, audioStart: TimeInterval, audioEnd: TimeInterval) {
        self.index = index
        self.ownedStart = ownedStart
        self.ownedEnd = ownedEnd
        self.audioStart = audioStart
        self.audioEnd = audioEnd
    }

    public var id: Int {
        index
    }

    public var ownedDuration: TimeInterval {
        ownedEnd - ownedStart
    }

    public var audioDuration: TimeInterval {
        audioEnd - audioStart
    }
}

public enum ChunkPlanner {
    /// Splits `duration` into consecutive owned ranges that cover [0, duration)
    /// exactly once. A short tail is merged into the previous chunk so the last
    /// unit is never a sliver that whisper would pad to a full window anyway.
    public static func plan(duration: TimeInterval, policy: ChunkPolicy) -> [AudioChunk] {
        guard duration.isFinite, duration > 0 else { return [] }
        let minimumTail = min(policy.chunkSeconds / 4, 10)
        var chunks: [AudioChunk] = []
        var start: TimeInterval = 0
        var index = 0
        while start < duration {
            var end = min(start + policy.chunkSeconds, duration)
            if duration - end < minimumTail {
                end = duration
            }
            chunks.append(AudioChunk(
                index: index,
                ownedStart: start,
                ownedEnd: end,
                audioStart: max(0, start - policy.overlapSeconds),
                audioEnd: min(duration, end + policy.overlapSeconds),
            ))
            start = end
            index += 1
        }
        return chunks
    }
}
