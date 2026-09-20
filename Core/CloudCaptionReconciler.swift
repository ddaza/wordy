import Foundation

/// Cloud captions use the same overlap stitch as local inference. Phrase times
/// from OpenRouter often overlap even when the text is new; only an exact
/// suffix/prefix match within the overlap word budget is dropped.
public enum CloudCaptionReconciler {
    public struct Result: Sendable {
        public let replacingLastSegment: TranscriptSegment?
        public let segments: [TranscriptSegment]
    }

    public static func commit(raw: [RawSegment], for chunk: AudioChunk, isLast: Bool,
                              after committed: [TranscriptSegment]) -> Result
    {
        Result(
            replacingLastSegment: nil,
            segments: ChunkReconciler.commit(raw: raw, for: chunk, isLast: isLast, after: committed),
        )
    }
}
