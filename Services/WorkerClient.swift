import Foundation

@MainActor
final class WorkerClient {
    private var connection: NSXPCConnection?
    private var pending: CheckedContinuation<String, Never>?
    private var timeout: Task<Void, Never>?

    func readiness() async -> String {
        if pending != nil {
            return "Checking local engine…"
        }
        return await withCheckedContinuation { continuation in
            pending = continuation
            let connection = NSXPCConnection(serviceName: WorkerIdentity.serviceName)
            self.connection = connection
            connection.remoteObjectInterface = NSXPCInterface(with: TranscriptionWorkerProtocol.self)
            connection.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.finish("Local engine service was interrupted.") }
            }
            connection.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.finish("Local engine service is unavailable.") }
            }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
                Task { @MainActor in self?.finish("Local engine service is unavailable.") }
            } as? TranscriptionWorkerProtocol
            proxy?.checkReadiness { [weak self] _, message in
                Task { @MainActor in self?.finish(message) }
            }
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.finish("Local engine service did not respond. Reopen the app to retry.")
            }
        }
    }

    private func finish(_ message: String) {
        guard let pending else { return }
        self.pending = nil
        timeout?.cancel()
        timeout = nil
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
        pending.resume(returning: message)
    }
}
