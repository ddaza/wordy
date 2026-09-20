import Foundation

protocol CloudTranscribing: Sendable {
    func transcribe(audioURL: URL, chunk: AudioChunk, sourceDuration: Double,
                    model: OpenRouterModel, apiKey: String) async throws -> OpenRouterTranscript
}

/// Serial, off-main audio preparation and HTTP. The coordinator grants consent
/// before invoking this adapter; cancellation is checked again before upload.
actor OpenRouterProvider: CloudTranscribing {
    private let sessionConfiguration: @Sendable () -> URLSessionConfiguration

    init(sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.sessionConfiguration = sessionConfiguration
    }

    func transcribe(audioURL: URL, chunk: AudioChunk, sourceDuration: Double,
                    model: OpenRouterModel, apiKey: String) async throws -> OpenRouterTranscript
    {
        try await OpenRouterSectionClient.transcribe(
            audioURL: audioURL, chunk: chunk, sourceDuration: sourceDuration, model: model, apiKey: apiKey,
            sessionConfiguration: sessionConfiguration,
        )
    }

    static func request(wav: Data, model: OpenRouterModel, apiKey: String) throws -> URLRequest {
        try OpenRouterSectionClient.request(wav: wav, model: model, apiKey: apiKey)
    }
}
