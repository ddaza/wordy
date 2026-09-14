import Foundation
import os

/// Owns the connection to the bundled XPC worker. An interrupted worker is
/// relaunched on the next message; the failed call surfaces as `.interrupted`
/// so the coordinator can retry the same chunk without losing committed work.
@MainActor
final class WorkerClient {
    enum WorkerError: LocalizedError, Equatable {
        case interrupted
        case unavailable
        case timedOut
        case invalidReply
        case failure(String)

        var errorDescription: String? {
            switch self {
            case .interrupted: "The local engine stopped unexpectedly and will be restarted."
            case .unavailable: "The local engine service is unavailable."
            case .timedOut: "The local engine did not respond in time."
            case .invalidReply: "The local engine returned an unreadable result."
            case let .failure(message): message
            }
        }
    }

    private var connection: NSXPCConnection?
    private let logger = Logger(subsystem: "com.wordy.app", category: "worker")

    /// XPC invokes the handlers below on its own queue. They must be explicitly
    /// `@Sendable` (nonisolated); a plain closure formed in this `@MainActor`
    /// method inherits main-actor isolation and Swift 6 traps when XPC calls it
    /// off the main thread.
    private func proxy(onError: @escaping @Sendable (WorkerError) -> Void) -> TranscriptionWorkerProtocol? {
        if connection == nil {
            let connection = NSXPCConnection(serviceName: WorkerIdentity.serviceName)
            connection.remoteObjectInterface = NSXPCInterface(with: TranscriptionWorkerProtocol.self)
            let logger = self.logger
            connection.interruptionHandler = { @Sendable in
                logger.warning("Transcription worker interrupted")
            }
            connection.invalidationHandler = { @Sendable [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            connection.resume()
            self.connection = connection
        }
        let handler: @Sendable (any Error) -> Void = { error in
            let code = (error as NSError).code
            onError(code == NSXPCConnectionInterrupted ? .interrupted : .unavailable)
        }
        return connection?.remoteObjectProxyWithErrorHandler(handler) as? TranscriptionWorkerProtocol
    }

    func readiness() async -> String {
        do {
            let description = try await describeEngine(timeout: .seconds(5))
            return "Engine ready · \(description.engineName) \(description.engineVersion) · \(description.gpuAvailable ? "Metal" : "CPU")"
        } catch WorkerError.timedOut {
            return "Local engine service did not respond. Reopen the app to retry."
        } catch {
            return error.localizedDescription
        }
    }

    func describeEngine(timeout: Duration = .seconds(15)) async throws -> EngineDescription {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)
            guard let proxy = proxy(onError: { box.fail($0) }) else {
                box.fail(.unavailable)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(timeout.milliseconds))) {
                box.fail(.timedOut)
            }
            proxy.describeEngine { data, message in
                if let data { box.succeed(data) } else { box.fail(.failure(message ?? WorkerError.unavailable.localizedDescription)) }
            }
        }
        return try decode(EngineDescription.self, from: data)
    }

    func transcribe(_ request: ChunkTranscriptionRequest) async throws -> ChunkTranscriptionResult {
        let payload = try MessageCoding.encode(request)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)
            guard let proxy = proxy(onError: { box.fail($0) }) else {
                box.fail(.unavailable)
                return
            }
            proxy.transcribeChunk(payload) { data, message in
                if let data { box.succeed(data) } else { box.fail(.failure(message ?? WorkerError.unavailable.localizedDescription)) }
            }
        }
        let result = try decode(ChunkTranscriptionResult.self, from: data)
        guard result.jobID == request.jobID, result.chunkIndex == request.chunkIndex else { throw WorkerError.invalidReply }
        return result
    }

    func cancel(jobID: UUID) {
        proxy(onError: { _ in })?.cancel(jobID: jobID.uuidString)
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try MessageCoding.decode(type, from: data)
        } catch {
            throw WorkerError.invalidReply
        }
    }
}

/// XPC guarantees either the reply or the error handler runs, but never both;
/// this box additionally makes a double resume impossible.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func succeed(_ data: Data) {
        take()?.resume(returning: data)
    }

    func fail(_ error: WorkerClient.WorkerError) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Data, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}
