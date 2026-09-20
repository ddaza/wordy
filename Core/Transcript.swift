import Foundation

public struct TranscriptSegment: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    /// Source phrase timing is ambiguous after overlap reconciliation.
    public let timingUncertain: Bool?

    public init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, text: String,
                timingUncertain: Bool = false)
    {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.timingUncertain = timingUncertain ? true : nil
    }

    func markingUncertain() -> Self {
        .init(id: id, start: start, end: end, text: text, timingUncertain: true)
    }
}

/// Immutable, validated timeline. Intervals are [start, end); silence stays silent.
public struct TranscriptTimeline: Sendable {
    public enum ValidationError: Error { case invalidInterval, overlappingSegments, duplicateID }
    public let segments: [TranscriptSegment]
    private let maximumEnds: [TimeInterval]

    public init(segments: [TranscriptSegment]) throws {
        var previousEnd: TimeInterval = 0
        var previousStart: TimeInterval = 0
        var maximumEnds: [TimeInterval] = []
        var ids = Set<UUID>()
        for segment in segments {
            guard segment.start.isFinite, segment.end.isFinite,
                  segment.start >= 0, segment.end > segment.start
            else {
                throw ValidationError.invalidInterval
            }
            guard segment.start >= previousStart,
                  segment.start >= previousEnd || segment.timingUncertain == true
            else { throw ValidationError.overlappingSegments }
            guard ids.insert(segment.id).inserted else { throw ValidationError.duplicateID }
            previousStart = segment.start
            previousEnd = max(previousEnd, segment.end)
            maximumEnds.append(previousEnd)
        }
        self.segments = segments
        self.maximumEnds = maximumEnds
    }

    public func activeSegment(at time: TimeInterval) -> TranscriptSegment? {
        activeSegments(at: time).last
    }

    /// Source intervals active now, including explicitly uncertain overlaps.
    /// Ending a contained phrase must not hide a longer surrounding interval.
    public func activeSegments(at time: TimeInterval) -> [TranscriptSegment] {
        guard time.isFinite, time >= 0 else { return [] }
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
        var active: [TranscriptSegment] = []
        while low > 0, maximumEnds[low - 1] > time {
            low -= 1
            if segments[low].end > time {
                active.append(segments[low])
            }
        }
        return active.reversed()
    }

    /// Player, transcript, and search use this so a missing overlap flag cannot
    /// blank the visible captions. Invalid intervals still cannot be presented.
    public static func presenting(_ segments: [TranscriptSegment]) -> (segments: [TranscriptSegment], timeline: TranscriptTimeline) {
        if let timeline = try? TranscriptTimeline(segments: segments) {
            return (segments, timeline)
        }
        var previousEnd: TimeInterval = 0
        let marked = segments.map { segment -> TranscriptSegment in
            let result = segment.start < previousEnd && segment.timingUncertain != true
                ? segment.markingUncertain() : segment
            previousEnd = max(previousEnd, segment.end)
            return result
        }
        if let timeline = try? TranscriptTimeline(segments: marked) {
            return (marked, timeline)
        }
        return (segments, try! TranscriptTimeline(segments: []))
    }
}
