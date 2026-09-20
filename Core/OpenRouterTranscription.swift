import Foundation

/// Only caption-capable models validated for this adapter are selectable.
public enum OpenRouterModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case whisperLargeV3 = "openai/whisper-large-v3"
    case whisperLargeV3Turbo = "openai/whisper-large-v3-turbo"

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .whisperLargeV3: "Whisper Large V3"
        case .whisperLargeV3Turbo: "Whisper Large V3 Turbo"
        }
    }

    public var configuration: TranscriptionConfiguration {
        .init(engineName: "OpenRouter", engineVersion: "stt-v1-wordy-1", modelID: rawValue,
              language: "auto", policy: .cloudDefault)
    }
}

/// Safe, actionable messages only. Never surface provider response bodies or URLs.
public enum OpenRouterError: Error, LocalizedError, Equatable {
    case authorizationRequired, missingKey, invalidKey, credits, rateLimited, unavailable
    case rejected, invalidResponse, missingTimestamps, tooLarge, network, sourceChanged, storage

    public var errorDescription: String? {
        switch self {
        case .authorizationRequired: "Enable Advanced Mode and confirm this recording before uploading."
        case .missingKey: "Save your OpenRouter API key in Settings first."
        case .invalidKey: "OpenRouter rejected the API key. Update it in Settings."
        case .credits: "Your OpenRouter account needs more credits."
        case .rateLimited: "OpenRouter is busy or rate limited. Wait before trying again."
        case .unavailable: "OpenRouter or its provider is unavailable. Try again later."
        case .rejected: "OpenRouter rejected this transcription request. Check the selected model and try again."
        case .invalidResponse: "OpenRouter returned an invalid transcript. The section was not saved."
        case .missingTimestamps: "The provider did not return usable caption timestamps. The section was not saved."
        case .tooLarge: "This audio section or response exceeds Wordy's size limit."
        case .network: "The OpenRouter connection was interrupted. Check your connection before retrying."
        case .sourceChanged: "The recording changed. Reopen Wordy and import the changed recording before transcribing it."
        case .storage: "The transcript could not be saved. Check available disk space before retrying."
        }
    }

    public static func httpStatus(_ status: Int) -> Self {
        switch status {
        case 401, 403: .invalidKey
        case 402: .credits
        case 429: .rateLimited
        case 413: .tooLarge
        case 500 ... 599: .unavailable
        default: .rejected
        }
    }
}

public struct OpenRouterTranscript: Sendable {
    public let segments: [RawSegment]
    public let language: String?
    public var usage: OpenRouterUsage?

    public static func decode(_ data: Data, audioStart: Double, audioDuration: Double,
                              sourceDuration: Double) throws -> Self
    {
        struct Response: Decodable {
            struct Segment: Decodable { let start: Double; let end: Double; let text: String }
            let text: String
            let language: String?
            let segments: [Segment]?
        }
        struct BillingResponse: Decodable { let usage: OpenRouterUsage? }
        guard data.count <= 2 * 1024 * 1024,
              audioStart.isFinite, audioStart >= 0, audioDuration.isFinite, audioDuration > 0,
              sourceDuration.isFinite, sourceDuration > audioStart,
              let response = try? JSONDecoder().decode(Response.self, from: data)
        else { throw OpenRouterError.invalidResponse }
        guard let segments = response.segments else { throw OpenRouterError.missingTimestamps }
        guard segments.count <= 4096 else { throw OpenRouterError.tooLarge }
        if segments.isEmpty, !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw OpenRouterError.missingTimestamps
        }
        var normalized: [RawSegment] = []
        var previousStart = -Double.infinity
        for segment in segments {
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0,
                  segment.end > segment.start, segment.start >= previousStart,
                  segment.start < audioDuration, segment.end <= audioDuration + 0.25,
                  segment.text.utf8.count <= 65536
            else { throw OpenRouterError.invalidResponse }
            previousStart = segment.start
            let start = audioStart + segment.start
            let end = min(audioStart + segment.end, audioStart + audioDuration, sourceDuration)
            guard end > start else { throw OpenRouterError.invalidResponse }
            if !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                normalized.append(.init(start: start, end: end, text: segment.text))
            }
        }
        if normalized.isEmpty, !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw OpenRouterError.missingTimestamps
        }
        return Self(segments: normalized, language: response.language.map { String($0.prefix(64)) }, usage: (try? JSONDecoder().decode(BillingResponse.self, from: data))?.usage)
    }
}

/// Decode, encode a PCM section, and POST it. Jobs and clip fixtures share this
/// path so pause/cancel, redirect refusal, and source checks stay in one place.
enum OpenRouterSectionClient {
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

    static func transcribe(audioURL: URL, chunk: AudioChunk, sourceDuration: Double,
                           model: OpenRouterModel, apiKey: String,
                           sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) async throws -> OpenRouterTranscript
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
                try Task.checkCancellation()
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
}

/// Do not forward a recording or credential to a redirect target.
final class NoCloudRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }
}

/// A bounded PCM WAV section; generated in memory and never written to disk.
enum CloudAudioEncoding {
    static func wav(_ samples: [Float]) throws -> Data {
        guard !samples.isEmpty, samples.count <= 80 * 16000 else { throw OpenRouterError.tooLarge }
        var data = Data()
        func ascii(_ value: String) {
            data.append(contentsOf: value.utf8)
        }
        func integer(_ value: some FixedWidthInteger) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); integer(UInt32(36 + samples.count * 2)); ascii("WAVEfmt ")
        integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1)); integer(UInt32(16000))
        integer(UInt32(32000)); integer(UInt16(2)); integer(UInt16(16))
        ascii("data"); integer(UInt32(samples.count * 2))
        for sample in samples {
            guard sample.isFinite else { throw OpenRouterError.invalidResponse }
            integer(Int16((max(-1, min(1, sample)) * 32767).rounded()))
        }
        return data
    }
}
