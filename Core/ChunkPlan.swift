import Foundation

/// Scheduling and checkpoint unit for long recordings. Each decoded window is
/// `chunkSeconds` long. The next window starts `overlapSeconds` before the
/// previous window ends, so a phrase cut at a seam is heard whole at least
/// once. Owned ranges still tile `[0, duration)` exactly once. Overlap never
/// changes the timeline: every result keeps absolute source timestamps.
public struct ChunkPolicy: Codable, Hashable, Sendable {
    public enum PolicyError: Error, Equatable { case invalidChunkLength, invalidOverlap }

    public let chunkSeconds: TimeInterval
    public let overlapSeconds: TimeInterval

    public init(chunkSeconds: TimeInterval, overlapSeconds: TimeInterval) throws {
        guard chunkSeconds.isFinite, chunkSeconds >= 5 else { throw PolicyError.invalidChunkLength }
        guard overlapSeconds.isFinite, overlapSeconds >= 0, overlapSeconds < chunkSeconds else {
            throw PolicyError.invalidOverlap
        }
        self.chunkSeconds = chunkSeconds
        self.overlapSeconds = overlapSeconds
    }

    /// Provisional default until the Milestone 1 benchmark settles the policy.
    public static let `default` = try! ChunkPolicy(chunkSeconds: 60, overlapSeconds: 3)

    /// OpenRouter Whisper emits coarse ~30 s phrases. Keep the same 60 s window
    /// as local jobs so seams are not denser than the provider grid, but use
    /// 10 s of overlap (local uses 3 s) so a phrase that starts on a boundary
    /// is still heard whole. Decoded window stays at 60 s, under the 80 s /
    /// 3 MiB PCM cap. A 50 s window was tried and placed seams through
    /// mid-sentence formula lists (e.g. herb names around 3:20 on a sample clip).
    public static let cloudDefault = try! ChunkPolicy(chunkSeconds: 60, overlapSeconds: 10)

    /// Whisper's decoder grid is ~30 s. A gold capture uses a 30 s window so
    /// the engine does not split the clip again without overlap. Overlap still
    /// comes from `overlapSeconds`, not a hardcoded start list.
    public static let gold = try! ChunkPolicy(chunkSeconds: 30, overlapSeconds: 3)

    public var label: String {
        "\(Int(chunkSeconds))s+\(Int(overlapSeconds))s"
    }

    /// Distance between consecutive window starts.
    public var strideSeconds: TimeInterval {
        chunkSeconds - overlapSeconds
    }

    /// Peak decoded seconds for any section.
    public var maximumAudioSeconds: TimeInterval {
        chunkSeconds
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

    /// Audio heard before the section's owned time.
    public var leadingOverlapSeconds: TimeInterval {
        max(0, ownedStart - audioStart)
    }
}

public enum ChunkPlanner {
    /// Splits `duration` into consecutive owned ranges that cover [0, duration)
    /// exactly once. Each decoded window is `policy.chunkSeconds` long and starts
    /// `policy.overlapSeconds` before the previous window ended. A final window
    /// shorter than `chunkSeconds` is kept as its own chunk so the engine never
    /// sees more than one native window of audio.
    public static func plan(duration: TimeInterval, policy: ChunkPolicy) -> [AudioChunk] {
        guard duration.isFinite, duration > 0 else { return [] }
        let window = policy.chunkSeconds
        let stride = policy.strideSeconds
        var chunks: [AudioChunk] = []
        var start: TimeInterval = 0
        var index = 0
        while start < duration {
            let audioEnd = min(duration, start + window)
            let isLast = audioEnd >= duration
            let ownedEnd = isLast ? duration : start + stride
            chunks.append(AudioChunk(
                index: index,
                ownedStart: start,
                ownedEnd: ownedEnd,
                audioStart: start,
                audioEnd: audioEnd,
            ))
            if isLast {
                break
            }
            start += stride
            index += 1
        }
        return chunks
    }
}
