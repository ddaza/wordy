import Foundation

public struct TranscriptSegment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Immutable, validated timeline. Intervals are [start, end); silence stays silent.
public struct TranscriptTimeline: Sendable {
    public enum ValidationError: Error { case invalidInterval, overlappingSegments, duplicateID }
    public let segments: [TranscriptSegment]

    public init(segments: [TranscriptSegment]) throws {
        var previousEnd: TimeInterval = 0
        var ids = Set<UUID>()
        for segment in segments {
            guard segment.start.isFinite, segment.end.isFinite,
                  segment.start >= 0, segment.end > segment.start
            else {
                throw ValidationError.invalidInterval
            }
            guard segment.start >= previousEnd else { throw ValidationError.overlappingSegments }
            guard ids.insert(segment.id).inserted else { throw ValidationError.duplicateID }
            previousEnd = segment.end
        }
        self.segments = segments
    }

    public func activeSegment(at time: TimeInterval) -> TranscriptSegment? {
        guard time.isFinite, time >= 0 else { return nil }
        var low = 0
        var high = segments.count
        while low < high {
            let middle = low + (high - low) / 2
            if segments[middle].start <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low > 0, time < segments[low - 1].end else { return nil }
        return segments[low - 1]
    }
}
