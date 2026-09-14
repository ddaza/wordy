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
        try data.write(to: destination, options: [.atomic])
    }

    /// Keep read/modify/write in one actor turn so an edit cannot be overwritten
    /// by a concurrent pin or removal using an older snapshot.
    func update(sha256: String, mutation: @Sendable (BookmarkSet) throws -> BookmarkSet) throws -> BookmarkSet {
        let set = try mutation(load(sha256: sha256))
        guard set.audioSHA256 == sha256 else { throw BookmarkSet.BookmarkError.digestMismatch }
        try save(set)
        return set
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
