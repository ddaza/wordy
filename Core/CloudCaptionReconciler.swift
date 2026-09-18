import Foundation

/// Cloud phrase times can overlap even when their text is distinct. Only a
/// matching suffix/prefix at an upload boundary proves duplicated text; time
/// overlap alone must never be converted into a number of words to delete.
///
/// Attribution matches local inference: a section commits every phrase that
/// *starts* before its owned end. Trailing upload context must be long enough
/// for provider phrase grids (~30 s for Whisper) or boundary words are lost —
/// see `ChunkPolicy.cloudDefault`.
public enum CloudCaptionReconciler {
    public struct Result: Sendable {
        public let replacingLastSegment: TranscriptSegment?
        public let segments: [TranscriptSegment]
    }

    public static func commit(raw: [RawSegment], for chunk: AudioChunk, isLast: Bool,
                              after committed: [TranscriptSegment]) -> Result
    {
        var tail = committed.last
        var result: [TranscriptSegment] = []
        let boundaryEnd = tail?.end ?? 0
        var boundaryWords = committed.suffix(32)
            .filter { $0.end > chunk.audioStart }
            .flatMap { ChunkReconciler.normalizedWords($0.text) }
        // Cap like the local reconciler so a long re-hearing cannot erase a
        // whole phrase through an accidental long prefix match.
        boundaryWords = Array(boundaryWords.suffix(ChunkReconciler.maximumBoundaryWords * 4))
        var atBoundary = !boundaryWords.isEmpty

        for candidate in raw {
            guard candidate.start.isFinite, candidate.end.isFinite, candidate.start >= 0,
                  candidate.end > candidate.start, isLast || candidate.start < chunk.ownedEnd else { continue }
            var text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !ChunkReconciler.isNonSpeechMarker(text) else { continue }
            // Context entirely before this chunk's ownership is already saved.
            if tail != nil, candidate.end <= min(chunk.ownedStart, boundaryEnd) {
                continue
            }
            if atBoundary, candidate.start < boundaryEnd {
                let incoming = ChunkReconciler.normalizedWords(text)
                let limit = min(ChunkReconciler.maximumBoundaryWords, boundaryWords.count, incoming.count)
                var duplicateCount = 0
                if limit > 0 {
                    for length in stride(from: limit, through: 1, by: -1) {
                        if Array(boundaryWords.suffix(length)) == Array(incoming.prefix(length)) {
                            duplicateCount = length
                            break
                        }
                    }
                }
                if duplicateCount > 0 {
                    text = ChunkReconciler.dropLeadingWords(duplicateCount, from: text)
                    if text.isEmpty {
                        continue
                    }
                }
            }
            // Never deduplicate successive phrases from the same response:
            // those words may be deliberate repetition with imprecise timing.
            atBoundary = false
            let previous = result.last ?? tail
            if let previous, candidate.start < previous.end {
                if candidate.start > previous.start {
                    // Resolve an overlap using the next phrase's supplied start,
                    // keeping all text and the stable identity of the prior row.
                    let shortened = TranscriptSegment(id: previous.id, start: previous.start,
                                                      end: candidate.start, text: previous.text)
                    if result.isEmpty {
                        tail = shortened
                    } else {
                        result[result.count - 1] = shortened
                    }
                } else {
                    // Contained/equal-start intervals cannot form two ordered
                    // rows. Keep both texts in their shared provider interval.
                    let merged = TranscriptSegment(id: previous.id, start: previous.start,
                                                   end: max(previous.end, candidate.end),
                                                   text: previous.text + " " + text)
                    if result.isEmpty {
                        tail = merged
                    } else {
                        result[result.count - 1] = merged
                    }
                    continue
                }
            }
            result.append(.init(start: candidate.start, end: candidate.end, text: text))
        }
        return Result(replacingLastSegment: tail != committed.last ? tail : nil, segments: result)
    }
}
