import Foundation

/// Black-box fold of planned chunks plus per-chunk engine output.
///
/// The coordinator owns I/O. Tests and jobs feed each engine's recorded raw
/// lists in order. Chunks never drop phrases; the stitch is the only cut.
public enum CaptionPipeline {
    /// Decoded-frame rounding at a section edge. Slightly longer engine ends are
    /// clamped; intervals farther outside the window are dropped from the stitch.
    public static let decodedWindowSlack: TimeInterval = 0.25

    public struct State: Sendable {
        public var committed: [TranscriptSegment] = []
        public var pending: [TranscriptSegment] = []

        public init(committed: [TranscriptSegment] = [], pending: [TranscriptSegment] = []) {
            self.committed = committed
            self.pending = pending
        }

        public mutating func append(raw: [RawSegment], chunk: AudioChunk, next: AudioChunk?) {
            // Also handles resuming a legacy checkpoint whose tail was already
            // published. No earlier finalized caption is rewritten.
            let boundary = committed.firstIndex { $0.end > chunk.audioStart - decodedWindowSlack } ?? committed.count
            let tail = Array(committed[boundary...]) + pending
            // Engines can round the final frame a few milliseconds past the
            // decoded window. Never extend captions beyond available audio.
            let bounded = raw.map {
                RawSegment(start: $0.start, end: min($0.end, chunk.audioEnd), text: $0.text,
                           noSpeechProbability: $0.noSpeechProbability)
            }
            let revised = ChunkReconciler.reconcile(raw: bounded, for: chunk, after: tail)
            committed.removeSubrange(boundary...)
            let cutoff = next.map { max(0, $0.audioStart - decodedWindowSlack) } ?? .infinity
            let provisional = revised.firstIndex { $0.end > cutoff } ?? revised.count
            committed.append(contentsOf: revised[..<provisional])
            pending = Array(revised[provisional...])
        }
    }

    public static func reconcile(plan: [AudioChunk], rawByChunk: [[RawSegment]]) -> [TranscriptSegment] {
        state(plan: plan, rawByChunk: rawByChunk).committed
    }

    public static func state(plan: [AudioChunk], rawByChunk: [[RawSegment]]) -> State {
        precondition(rawByChunk.count <= plan.count, "raw lists must be a prefix of the plan")
        var state = State()
        for index in rawByChunk.indices {
            state.append(raw: rawByChunk[index], chunk: plan[index],
                         next: index + 1 < plan.count ? plan[index + 1] : nil)
        }
        return state
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
