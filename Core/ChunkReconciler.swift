import Foundation

/// Engine output for one chunk, already shifted to absolute source time.
public struct RawSegment: Codable, Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    public let noSpeechProbability: Float

    public init(start: TimeInterval, end: TimeInterval, text: String, noSpeechProbability: Float = 0) {
        self.start = start
        self.end = end
        self.text = text
        self.noSpeechProbability = noSpeechProbability
    }
}

/// Turns raw chunk output into committed, monotonic segments.
///
/// Attribution: a chunk commits every segment that *starts* before its owned
/// end. A sentence straddling the boundary is therefore committed by the chunk
/// that heard it with context on both sides (its window extends `overlap`
/// seconds past the boundary) rather than by the next chunk, which starts
/// mid-sentence. The next chunk's re-hearing of already-committed time is
/// trimmed only when a prefix of its text exactly matches a suffix of the
/// previous caption. The match may be longer than the overlap; at most
/// `boundaryWordBudget` leading words are dropped (about 3–4 at 3 s, more
/// at 5–10 s). Time overlap alone never deletes distinct words.
public enum ChunkReconciler {
    public static func commit(raw: [RawSegment], for chunk: AudioChunk, isLast: Bool,
                              after committed: [TranscriptSegment]) -> [TranscriptSegment]
    {
        var previousEnd = committed.last?.end ?? 0
        var previousWords = committed.last.map { normalizedWords($0.text) } ?? []
        var result: [TranscriptSegment] = []
        let budget = ChunkPolicy.boundaryWordBudget(overlapSeconds: chunk.leadingOverlapSeconds)

        let candidates = raw
            .filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .filter { isLast || $0.start < chunk.ownedEnd }
            .sorted { $0.start < $1.start }

        for candidate in candidates {
            var text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isNonSpeechMarker(text) else { continue }
            guard candidate.end > previousEnd else { continue } // entirely inside committed time
            var start = candidate.start
            if start < previousEnd {
                let incoming = normalizedWords(text)
                let match = sharedBoundaryWords(trailing: previousWords, leading: incoming)
                let overlap = min(match, budget)
                if overlap > 0 {
                    text = dropLeadingWords(overlap, from: text)
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
            previousWords = normalizedWords(text)
        }
        return result
    }

    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }
    }

    /// Length of the longest suffix of `trailing` equal to a prefix of `leading`.
    static func sharedBoundaryWords(trailing: [String], leading: [String],
                                    limit: Int = .max) -> Int
    {
        let limit = min(max(limit, 1), trailing.count, leading.count)
        for length in stride(from: limit, through: 1, by: -1) {
            if Array(trailing.suffix(length)) == Array(leading.prefix(length)) {
                return length
            }
        }
        return 0
    }

    static func dropLeadingWords(_ count: Int, from text: String) -> String {
        var remaining = count
        var scalars = Substring(text)
        while remaining > 0 {
            scalars = scalars.drop { $0.isWhitespace }
            guard let wordEnd = scalars.firstIndex(where: \.isWhitespace) else { return "" }
            scalars = scalars[wordEnd...]
            remaining -= 1
        }
        return scalars.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper emits bracketed markers for music, applause, or blank audio.
    /// They are not lecture content and must not become captions.
    static func isNonSpeechMarker(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return true }
        let opens: Set<Character> = ["[", "(", "*", "♪"]
        let closes: Set<Character> = ["]", ")", "*", "♪"]
        return opens.contains(first) && closes.contains(last)
    }
}
