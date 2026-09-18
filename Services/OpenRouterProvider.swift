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
        try Task.checkCancellation()
        let sourceVersion = try AudioSourceVersion.read(audioURL)
        let source = try await AudioChunkDecoder.prepare(url: audioURL)
        let decoded = try AudioChunkDecoder.decode(source, start: chunk.audioStart, end: chunk.audioEnd,
                                                   isCancelled: { Task.isCancelled })
        let wav = try CloudAudioEncoding.wav(decoded.samples)
        try Task.checkCancellation()
        guard try AudioSourceVersion.read(audioURL) == sourceVersion else { throw OpenRouterError.sourceChanged }
        let request = try Self.request(wav: wav, model: model, apiKey: apiKey)
        let configuration = sessionConfiguration()
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: configuration, delegate: NoCloudRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw OpenRouterError.invalidResponse }
            guard http.statusCode == 200 else { throw OpenRouterError.httpStatus(http.statusCode) }
            guard response.expectedContentLength <= 2 * 1024 * 1024 else { throw OpenRouterError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 2 * 1024 * 1024 else { throw OpenRouterError.tooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return try OpenRouterTranscript.decode(data, audioStart: decoded.startTime,
                                                   audioDuration: decoded.duration, sourceDuration: sourceDuration)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OpenRouterError {
            throw error
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw OpenRouterError.network
        }
    }

    static func request(wav: Data, model: OpenRouterModel, apiKey: String) throws -> URLRequest {
        guard !apiKey.isEmpty, !apiKey.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw OpenRouterError.missingKey
        }
        guard wav.count <= 3 * 1024 * 1024 else { throw OpenRouterError.tooLarge }
        let boundary = "Wordy-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) {
            body.append(contentsOf: string.utf8)
        }
        for (name, value) in [("model", model.rawValue), ("response_format", "verbose_json"),
                              ("timestamp_granularities[]", "segment")]
        {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"section.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }
}

/// Do not forward a recording or credential to a redirect target.
private final class NoCloudRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }
}
