import Foundation
import Testing
#if SWIFT_PACKAGE
    import WordyCore
#endif

@Test func `captions use half open intervals and preserve silence`() throws {
    let first = TranscriptSegment(start: 0, end: 10, text: "First")
    let second = TranscriptSegment(start: 12, end: 20, text: "Second")
    let timeline = try TranscriptTimeline(segments: [first, second])
    #expect(timeline.activeSegment(at: 0)?.id == first.id)
    #expect(timeline.activeSegment(at: 9.99)?.id == first.id)
    #expect(timeline.activeSegment(at: 10) == nil)
    #expect(timeline.activeSegment(at: 11) == nil)
    #expect(timeline.activeSegment(at: 12)?.id == second.id)
    #expect(timeline.activeSegment(at: 20) == nil)
    #expect(timeline.activeSegment(at: -.infinity) == nil)
    #expect(timeline.activeSegment(at: .nan) == nil)
}

@Test func `adjacent captions and nonsequential seeks`() throws {
    let segments = (0 ..< 1440).map { index in
        TranscriptSegment(start: Double(index * 10), end: Double(index * 10 + 10), text: "Passage \(index)")
    }
    let timeline = try TranscriptTimeline(segments: segments)
    #expect(timeline.activeSegment(at: 7200)?.id == segments[720].id)
    #expect(timeline.activeSegment(at: 10)?.id == segments[1].id)
    #expect(timeline.activeSegment(at: 14399)?.id == segments.last?.id)
    #expect(timeline.activeSegment(at: 14400) == nil)
}

@Test func `rejects invalid or ambiguous timelines`() {
    for segment in [
        TranscriptSegment(start: -1, end: 1, text: ""),
        TranscriptSegment(start: 1, end: 1, text: ""),
        TranscriptSegment(start: 0, end: .infinity, text: ""),
    ] {
        #expect(throws: TranscriptTimeline.ValidationError.self) { try TranscriptTimeline(segments: [segment]) }
    }
    #expect(throws: TranscriptTimeline.ValidationError.self) {
        try TranscriptTimeline(segments: [
            .init(start: 0, end: 10, text: ""), .init(start: 5, end: 15, text: ""),
        ])
    }
    let id = UUID()
    #expect(throws: TranscriptTimeline.ValidationError.self) {
        try TranscriptTimeline(segments: [
            .init(id: id, start: 0, end: 5, text: ""), .init(id: id, start: 5, end: 10, text: ""),
        ])
    }
}

@Test func `search finds phrases across captions and maps original time`() {
    let segments: [TranscriptSegment] = [
        .init(start: 120, end: 125, text: "We discuss neural"),
        .init(start: 125, end: 130, text: "networks and café culture."),
    ]
    let hits = TranscriptSearch.hits(in: segments, query: "NEURAL networks")
    #expect(hits.count == 1)
    #expect(hits.first?.time == 120)
    #expect(hits.first?.id == segments[0].id)
    #expect(TranscriptSearch.hits(in: segments, query: "cafe").first?.time == 125)
    #expect(TranscriptSearch.hits(in: segments, query: "  ").isEmpty)
    #expect(TranscriptSearch.hits(in: segments, query: "missing").isEmpty)
}

@Test func `search handles unicode and deduplicates passages`() {
    let segments: [TranscriptSegment] = [.init(start: 0, end: 5, text: "🎧 café café")]
    #expect(TranscriptSearch.hits(in: segments, query: "cafe").count == 1)
}

@Test func `transcription requests accept only local files`() throws {
    let url = URL(fileURLWithPath: "/tmp/example.wav")
    #expect(try TranscriptionRequest(audioURL: url).audioURL == url)
    #expect(throws: TranscriptionRequest.RequestError.self) {
        try TranscriptionRequest(audioURL: #require(URL(string: "https://example.com/audio.wav")))
    }
}
