import Foundation

/// XPC entry point. One inference session serves every connection so the loaded
/// model is shared and inference stays serialized on a single worker.
final class TranscriptionWorker: NSObject, TranscriptionWorkerProtocol {
    private let session: InferenceSession

    init(session: InferenceSession) {
        self.session = session
    }

    func checkReadiness(reply: @escaping @Sendable (Bool, String) -> Void) {
        let description = session.describe()
        let backend = description.gpuAvailable ? "Metal" : "CPU"
        reply(true, "Engine ready · \(description.engineName) \(description.engineVersion) · \(backend)")
    }

    func describeEngine(reply: @escaping @Sendable (Data?, String?) -> Void) {
        do {
            try reply(MessageCoding.encode(session.describe()), nil)
        } catch {
            reply(nil, "The engine description could not be encoded.")
        }
    }

    func transcribeChunk(_ request: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        let decoded: ChunkTranscriptionRequest
        do {
            decoded = try MessageCoding.decode(ChunkTranscriptionRequest.self, from: request)
        } catch {
            reply(nil, "The transcription request was not understood by the local engine.")
            return
        }
        let session = session
        Task {
            do {
                let result = try await session.transcribe(decoded)
                try reply(MessageCoding.encode(result), nil)
            } catch is CancellationError {
                reply(nil, WhisperEngineError.cancelled.localizedDescription)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    func cancel(jobID: String) {
        session.cancel(jobID: jobID)
    }

    func unloadModel(reply: @escaping @Sendable () -> Void) {
        let session = session
        Task {
            await session.unloadModel()
            reply()
        }
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    let session = InferenceSession()

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: TranscriptionWorkerProtocol.self)
        connection.exportedObject = TranscriptionWorker(session: session)
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
