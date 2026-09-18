import Foundation

/// A request for an on-device transcription adapter. Requests only accept local
/// file URLs. Explicitly consented OpenRouter uploads use a separate adapter.
public struct TranscriptionRequest: Sendable {
    public enum RequestError: Error { case localFileRequired }
    public let id: UUID
    public let audioURL: URL

    public init(audioURL: URL) throws {
        guard audioURL.isFileURL else { throw RequestError.localFileRequired }
        id = UUID()
        self.audioURL = audioURL
    }
}

public struct TranscriptionBatch: Sendable {
    public let segments: [TranscriptSegment]
    public let completedThrough: TimeInterval
    public let engineVersion: String
    public let modelVersion: String
}

/// Engine adapters share result types without sharing job lifecycle internals,
/// so an alternative on-device engine can be evaluated behind the same contract.
public protocol TranscriptionProvider: Sendable {
    func transcribe(_ request: TranscriptionRequest) -> AsyncThrowingStream<TranscriptionBatch, Error>
    func cancel(requestID: UUID) async
}
