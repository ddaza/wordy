import Foundation

/// Cheap source invalidation between sections; content identity remains SHA-256.
/// Read off the main actor, like the audio file itself.
struct AudioSourceVersion: Equatable, Sendable {
    let size: UInt64
    let modified: Date
    let fileNumber: UInt64

    static func read(_ url: URL) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let number = attributes[.systemFileNumber] as? NSNumber
        else {
            throw OpenRouterError.sourceChanged
        }
        return Self(size: size.uint64Value, modified: modified, fileNumber: number.uint64Value)
    }
}
