import Foundation

public struct TranscriptSearchHit: Identifiable, Sendable {
    public let id: UUID
    public let time: TimeInterval
    public let text: String
}

/// Small in-memory scaffold search, including phrases spanning adjacent captions.
/// Replace with GRDB/FTS5 before adding a persistent or large transcript library.
public enum TranscriptSearch {
    public static func hits(in segments: [TranscriptSegment], query: String) -> [TranscriptSearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var document = ""
        var offsets: [(offset: Int, segment: TranscriptSegment)] = []
        for segment in segments {
            if !document.isEmpty {
                document += " "
            }
            offsets.append((document.utf16.count, segment))
            document += segment.text
        }
        let source = document as NSString
        var remaining = NSRange(location: 0, length: source.length)
        var results: [TranscriptSearchHit] = []
        var seen = Set<UUID>()
        while remaining.length > 0 {
            let match = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: remaining)
            guard match.location != NSNotFound else { break }
            if let item = offsets.last(where: { $0.offset <= match.location }), seen.insert(item.segment.id).inserted {
                results.append(.init(id: item.segment.id, time: item.segment.start, text: item.segment.text))
            }
            let next = NSMaxRange(match)
            remaining = NSRange(location: next, length: source.length - next)
        }
        return results
    }
}
