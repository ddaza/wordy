import Foundation

/// Turns cloud section output into committed, monotonic captions.
///
/// OpenRouter phrase times often overlap even when the text is new. Unlike the
/// earlier shorten/merge approach (which crushed prior rows and left timeline
/// gaps), this matches local attribution: clamp an overlapping phrase to start
/// at the previous end, and drop leading words only when they exactly match the
/// committed boundary. Time overlap alone never deletes distinct words.
///
/// The exact-match window is larger than local inference because cloud sections
/// re-hear 15 s of context and often re-emit a whole prior sentence.
public enum CloudCaptionReconciler {
    public static let maximumBoundaryWords = 32

    public struct Result: Sendable {
        public let replacingLastSegment: TranscriptSegment?
        public let segments: [TranscriptSegment]
    }

    public static func commit(raw: [RawSegment], for chunk: AudioChunk, isLast: Bool,
                              after committed: [TranscriptSegment]) -> Result
    {
        var previousEnd = committed.last?.end ?? 0
        var previousWords = committed.last.map { ChunkReconciler.normalizedWords($0.text) } ?? []
        var result: [TranscriptSegment] = []

        let candidates = raw
            .filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && $0.start >= 0 }
            .filter { isLast || $0.start < chunk.ownedEnd }
            .sorted { $0.start < $1.start }

        for candidate in candidates {
            var text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !ChunkReconciler.isNonSpeechMarker(text) else { continue }
            guard candidate.end > previousEnd else { continue }

            var start = candidate.start
            if start < previousEnd {
                let incoming = ChunkReconciler.normalizedWords(text)
                let overlap = sharedBoundaryWords(trailing: previousWords, leading: incoming)
                if overlap > 0 {
                    text = ChunkReconciler.dropLeadingWords(overlap, from: text)
                }
                guard !text.isEmpty else { continue }
                start = previousEnd
            }

            var end = max(candidate.end, start)
            if end <= start {
                end = start + 0.1
            }
            let segment = TranscriptSegment(start: start, end: end, text: text)
            result.append(segment)
            previousEnd = end
            previousWords = ChunkReconciler.normalizedWords(text)
        }
        return Result(replacingLastSegment: nil, segments: result)
    }

    /// Longest exact suffix/prefix match, capped at `maximumBoundaryWords`.
    static func sharedBoundaryWords(trailing: [String], leading: [String]) -> Int {
        let limit = min(maximumBoundaryWords, trailing.count, leading.count)
        for length in stride(from: limit, through: 1, by: -1) {
            if Array(trailing.suffix(length)) == Array(leading.prefix(length)) {
                return length
            }
        }
        return 0
    }
}
