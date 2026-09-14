import Foundation

public enum TranscriptionMode: String, Sendable { case local, cloud }

public struct TranscriptionRequest: Sendable {
    public enum RequestError: Error { case cloudConsentRequired, localFileRequired }
    public let id: UUID
    public let audioURL: URL
    public let mode: TranscriptionMode

    public init(audioURL: URL, mode: TranscriptionMode = .local, explicitCloudConsent: Bool = false) throws {
        guard audioURL.isFileURL else { throw RequestError.localFileRequired }
        guard mode != .cloud || explicitCloudConsent else { throw RequestError.cloudConsentRequired }
        id = UUID()
        self.audioURL = audioURL
        self.mode = mode
    }
}

public struct TranscriptionBatch: Sendable {
    public let segments: [TranscriptSegment]
    public let completedThrough: TimeInterval
    public let engineVersion: String
    public let modelVersion: String
}

/// Future local/cloud adapters share result types without sharing job lifecycle internals.
public protocol TranscriptionProvider: Sendable {
    func transcribe(_ request: TranscriptionRequest) -> AsyncThrowingStream<TranscriptionBatch, Error>
    func cancel(requestID: UUID) async
}

/// Bootstrap contract only. Add bounded, versioned inference messages with the engine adapter.
@objc public protocol TranscriptionWorkerProtocol {
    func checkReadiness(reply: @escaping @Sendable (Bool, String) -> Void)
}

public enum WorkerIdentity {
    public static let serviceName = "com.wordy.app.TranscriptionService"
}
