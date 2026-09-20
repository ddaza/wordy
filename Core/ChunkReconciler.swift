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

/// Reconciles text only against the preceding section's time-local phrases.
/// Distinct speech keeps its source interval, even when the engine's coarse
/// times conflict. Such intervals are explicitly marked uncertain, not moved
/// later or discarded. There is no words-per-second deletion allowance.
public enum ChunkReconciler {
    public static let revision = 2

    private struct TokenID: Hashable {
        let segmentID: UUID
        let offset: Int
    }

    /// Additions before sorting with the existing boundary. Production callers
    /// use reconcile so incoming phrases can precede a previous trailing cue.
    public static func commit(raw: [RawSegment], for chunk: AudioChunk,
                              after committed: [TranscriptSegment]) -> [TranscriptSegment]
    {
        let boundary = committed.filter { $0.end > chunk.audioStart - CaptionPipeline.decodedWindowSlack }
        let candidates = raw.enumerated().filter {
            $0.element.start.isFinite && $0.element.end.isFinite
                && $0.element.start >= 0 && $0.element.end > $0.element.start
        }.sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }
        var result: [TranscriptSegment] = []
        var consumed = Set<TokenID>()
        for (_, candidate) in candidates {
            var text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isNonSpeechMarker(text) else { continue }
            let overlapping = boundary.filter { $0.start < candidate.end && $0.end > candidate.start }
            let words = normalizedWords(text)
            // Match whole incoming phrases, or an incoming prefix against the
            // preceding suffix. Never erase text before a mid-string anchor.
            let contextTokens = overlapping.flatMap { segment in
                normalizedWords(segment.text).enumerated().map {
                    (id: TokenID(segmentID: segment.id, offset: $0.offset), word: $0.element, end: segment.end)
                }
            }
            // A previous occurrence can explain only one incoming occurrence.
            // Keep consumed slots as barriers so separate matches cannot join.
            let context = contextTokens.map { consumed.contains($0.id) ? "\u{0}" : $0.word }
            var trimmed = false
            var start = candidate.start
            if !words.isEmpty, !context.isEmpty {
                let exactInterval = overlapping.contains {
                    abs($0.start - candidate.start) < 0.05 && abs($0.end - candidate.end) < 0.05
                        && normalizedWords($0.text) == words
                }
                let strongPhrase = words.count >= 3 && Set(words).count >= 2
                if exactInterval || strongPhrase, let range = firstMatch(context, phrase: words) {
                    consumed.formUnion(contextTokens[range].map(\.id))
                    continue
                }
                let match = sharedBoundaryWords(trailing: context, leading: words)
                // Short/common-word coincidences and "again again" are not
                // enough evidence to remove deliberate repeated speech.
                let matchedEnd = contextTokens.last?.end ?? candidate.start
                if match >= 3, Set(words.prefix(match)).count >= 2, matchedEnd < candidate.end {
                    consumed.formUnion(contextTokens.suffix(match).map(\.id))
                    text = dropLeadingWords(match, from: text)
                    trimmed = true
                    // Only a matching preceding phrase supplies evidence for
                    // this boundary. Never apply this to disagreeing text.
                    start = matchedEnd
                }
            }
            guard !text.isEmpty else { continue }
            let overlapInSection = result.contains { $0.start < candidate.end && $0.end > candidate.start }
            result.append(.init(start: start, end: candidate.end, text: text,
                                timingUncertain: trimmed || !overlapping.isEmpty || overlapInSection))
        }
        return result
    }

    /// Returns the revised boundary, preserving IDs and unmatched source times.
    /// The checkpoint passes only its bounded provisional tail here.
    public static func reconcile(raw: [RawSegment], for chunk: AudioChunk,
                                 after committed: [TranscriptSegment]) -> [TranscriptSegment]
    {
        let added = commit(raw: raw, for: chunk, after: committed)
        var merged = (committed + added).enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        var end: TimeInterval = 0
        for index in merged.indices {
            if merged[index].start < end {
                merged[index] = merged[index].markingUncertain()
            }
            end = max(end, merged[index].end)
        }
        return merged
    }

    static func normalizedWords(_ text: String) -> [String] {
        tokens(text).map(\.word)
    }

    private static func tokens(_ text: String) -> [(word: String, end: String.Index)] {
        text.split(whereSeparator: \.isWhitespace).compactMap { token in
            let word = token.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            return word.isEmpty ? nil : (word, token.endIndex)
        }
    }

    private static func firstMatch(_ words: [String], phrase: [String]) -> Range<Int>? {
        guard !phrase.isEmpty, words.count >= phrase.count else { return nil }
        for start in 0 ... words.count - phrase.count {
            let range = start ..< start + phrase.count
            if words[range].elementsEqual(phrase) {
                return range
            }
        }
        return nil
    }

    static func sharedBoundaryWords(trailing: [String], leading: [String]) -> Int {
        let limit = min(trailing.count, leading.count)
        guard limit > 0 else { return 0 }
        for length in stride(from: limit, through: 1, by: -1) {
            if trailing.suffix(length).elementsEqual(leading.prefix(length)) {
                return length
            }
        }
        return 0
    }

    static func dropLeadingWords(_ count: Int, from text: String) -> String {
        let words = tokens(text)
        guard count > 0 else { return text }
        guard count < words.count else { return "" }
        return text[words[count - 1].end...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Match known whole markers, not every parenthesized spoken sentence.
    static func isNonSpeechMarker(_ text: String) -> Bool {
        let marker = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let names: Set = ["blank_audio", "silence", "music", "applause", "laughter", "inaudible"]
        if marker == "♪" || marker == "♫" {
            return true
        }
        for (open, close) in [("[", "]"), ("(", ")"), ("*", "*"), ("♪", "♪")] {
            if marker.hasPrefix(open), marker.hasSuffix(close), marker.count > 2 {
                return names.contains(String(marker.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces))
            }
        }
        return false
    }
}
