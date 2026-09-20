import Foundation

/// Which overlap rule to apply when folding chunk engine output into captions.
public enum CaptionEngineKind: String, Codable, Sendable, CaseIterable {
    case local
    case cloud
}

/// Black-box fold of planned chunks plus per-chunk engine output.
///
/// The coordinator owns I/O. Tests and jobs feed each engine's recorded raw
/// lists; stitching is the same overlap word budget for local and cloud.
public enum CaptionPipeline {
    public static func reconcile(plan: [AudioChunk], rawByChunk: [[RawSegment]],
                                 engine _: CaptionEngineKind = .local) -> [TranscriptSegment]
    {
        precondition(plan.count == rawByChunk.count, "each planned chunk needs one raw list")
        var committed: [TranscriptSegment] = []
        for (index, chunk) in plan.enumerated() {
            committed += ChunkReconciler.commit(
                raw: rawByChunk[index], for: chunk, isLast: index == plan.count - 1, after: committed,
            )
        }
        return committed
    }
}

public protocol TimedCaption {
    var start: TimeInterval { get }
    var end: TimeInterval { get }
    var text: String { get }
}

extension TranscriptSegment: TimedCaption {}
extension RawSegment: TimedCaption {}

/// Multiset word coverage for black-box caption comparisons.
public enum TranscriptCoverage {
    public static func normalizedWords(_ text: String) -> [String] {
        ChunkReconciler.normalizedWords(text)
    }

    public static func words<S: Sequence>(in segments: S, overlapping start: TimeInterval,
                                          end: TimeInterval) -> [String] where S.Element: TimedCaption
    {
        segments.flatMap { segment -> [String] in
            guard segment.end > start, segment.start < end else { return [] }
            return normalizedWords(segment.text)
        }
    }

    public static func words<S: Sequence>(in segments: S) -> [String] where S.Element: TimedCaption {
        segments.flatMap { normalizedWords($0.text) }
    }

    /// Expected tokens not consumed by actual, in order.
    public static func missing(expected: [String], actual: [String]) -> [String] {
        var remaining = actual
        var missing: [String] = []
        for word in expected {
            if let index = remaining.firstIndex(of: word) {
                remaining.remove(at: index)
            } else {
                missing.append(word)
            }
        }
        return missing
    }
}
