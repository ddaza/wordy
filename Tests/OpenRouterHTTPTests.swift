#if !SWIFT_PACKAGE
    import Foundation
    import Testing

    private final class HTTPFixture: @unchecked Sendable {
        private let lock = NSLock()
        private var status = 200
        private var body = Data()
        private var failure = false
        private var count = 0
        func configure(status: Int, body: Data, failure: Bool = false) {
            lock.lock(); defer { lock.unlock() }
            self.status = status; self.body = body; self.failure = failure; count = 0
        }

        func response() -> (Int, Data, Bool) {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return (status, body, failure)
        }

        var requests: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }

    private final class StubOpenRouterHTTP: URLProtocol, @unchecked Sendable {
        static let fixture = HTTPFixture()
        override class func canInit(with _: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            let (status, body, failure) = Self.fixture.response()
            if failure {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    @Suite(.serialized)
    struct OpenRouterHTTPTests {
        @Test func `HTTP errors and lost connections do not retry or expose provider text`() async throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try CloudAudioEncoding.wav([Float](repeating: 0, count: 16000)).write(to: url)
            let provider = OpenRouterProvider {
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [StubOpenRouterHTTP.self]
                return config
            }
            let chunk = AudioChunk(index: 0, ownedStart: 0, ownedEnd: 1, audioStart: 0, audioEnd: 1)
            for (status, expected) in [(401, OpenRouterError.invalidKey), (403, .invalidKey), (402, .credits),
                                       (429, .rateLimited), (503, .unavailable), (413, .tooLarge), (400, .rejected), (307, .rejected)]
            {
                StubOpenRouterHTTP.fixture.configure(status: status, body: Data("private provider diagnostic".utf8))
                do {
                    _ = try await provider.transcribe(audioURL: url, chunk: chunk, sourceDuration: 1,
                                                      model: .whisperLargeV3, apiKey: "test-key")
                    Issue.record("Expected HTTP failure")
                } catch {
                    #expect(error as? OpenRouterError == expected)
                    #expect(!error.localizedDescription.contains("private provider diagnostic"))
                }
                #expect(StubOpenRouterHTTP.fixture.requests == 1)
            }
            StubOpenRouterHTTP.fixture.configure(status: 200, body: Data(), failure: true)
            do {
                _ = try await provider.transcribe(audioURL: url, chunk: chunk, sourceDuration: 1,
                                                  model: .whisperLargeV3, apiKey: "test-key")
                Issue.record("Expected connection failure")
            } catch { #expect(error as? OpenRouterError == .network) }
            #expect(StubOpenRouterHTTP.fixture.requests == 1)
        }

        @Test func `real decoder and HTTP adapter return caption times without live uploads`() async throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try CloudAudioEncoding.wav([Float](repeating: 0, count: 10 * 16000)).write(to: url)
            let provider = OpenRouterProvider {
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [StubOpenRouterHTTP.self]
                return config
            }
            StubOpenRouterHTTP.fixture.configure(status: 200, body: Data(#"{"text":"Synthetic","segments":[{"start":1,"end":2,"text":"Synthetic"}]}"#.utf8))
            let result = try await provider.transcribe(audioURL: url,
                                                       chunk: .init(index: 0, ownedStart: 5, ownedEnd: 10, audioStart: 5, audioEnd: 10),
                                                       sourceDuration: 10, model: .whisperLargeV3, apiKey: "test-key")
            #expect(abs((result.segments.first?.start ?? 0) - 6) < 0.001)
            #expect(abs((result.segments.first?.end ?? 0) - 7) < 0.001)
            #expect(StubOpenRouterHTTP.fixture.requests == 1)
        }

        @Test func `multipart request sends only the section with a generic filename`() throws {
            let wav = try CloudAudioEncoding.wav([0, 1, 0])
            let request = try OpenRouterProvider.request(wav: wav, model: .whisperLargeV3, apiKey: "test-key")
            #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/audio/transcriptions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            let data = try #require(request.httpBody)
            let body = String(decoding: data, as: UTF8.self)
            #expect(body.contains("filename=\"section.wav\""))
            #expect(body.contains("verbose_json"))
            #expect(body.contains("timestamp_granularities[]"))
            #expect(data.range(of: wav) != nil)
        }
    }
#endif
