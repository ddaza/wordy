import Foundation

final class TranscriptionWorker: NSObject, TranscriptionWorkerProtocol {
    func checkReadiness(reply: @escaping @Sendable (Bool, String) -> Void) {
        reply(false, "Service connected. Speech model not installed.")
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: TranscriptionWorkerProtocol.self)
        connection.exportedObject = TranscriptionWorker()
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
