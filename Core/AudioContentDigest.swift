import CryptoKit
import Foundation

/// Streaming SHA-256 over a file's encoded bytes. Memory stays bounded by the
/// buffer size regardless of recording length. This blocks the calling thread;
/// run it off the main actor.
public enum AudioContentDigest {
    public static let defaultBufferSize = 1 << 20

    public static func sha256(of url: URL, bufferSize: Int = defaultBufferSize,
                              isCancelled: () -> Bool = { false }) throws -> String
    {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if isCancelled() { throw CancellationError() }
            guard let data = try handle.read(upToCount: bufferSize), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
