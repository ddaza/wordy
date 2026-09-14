import Foundation

/// One JSON document per audio SHA-256. Reads and writes always take that digest;
/// a file for another recording is never opened as a side effect of the wrong key.
actor BookmarkStore {
    private let directory: URL

    init(directory: URL = AppDirectories.bookmarks) {
        self.directory = directory
    }

    func load(sha256: String) throws -> BookmarkSet {
        guard BookmarkSet.isDigest(sha256) else { throw BookmarkSet.BookmarkError.invalidDigest }
        let url = fileURL(sha256: sha256)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return try BookmarkSet(audioSHA256: sha256)
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let set = try decoder.decode(BookmarkSet.self, from: data)
        guard set.audioSHA256 == sha256 else { throw BookmarkSet.BookmarkError.digestMismatch }
        try set.validateMembershipForStore()
        return set
    }

    func save(_ set: BookmarkSet) throws {
        try set.validateMembershipForStore()
        try AppDirectories.ensureExists(directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(set)
        let destination = fileURL(sha256: set.audioSHA256)
        let temporary = directory.appendingPathComponent(".\(set.audioSHA256).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    }

    private func fileURL(sha256: String) -> URL {
        directory.appendingPathComponent("\(sha256).json")
    }
}

private extension BookmarkSet {
    func validateMembershipForStore() throws {
        try validated(againstDuration: .greatestFiniteMagnitude)
    }
}
