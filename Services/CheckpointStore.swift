import Foundation

/// Milestone 1 checkpoint persistence: one JSON document per audio-content
/// digest, replaced atomically so an interrupted write can never leave a
/// half-written transcript. Milestone 2 moves this into GRDB.
actor CheckpointStore {
    private let directory: URL

    init(directory: URL = AppDirectories.transcripts) {
        self.directory = directory
    }

    func load(sha256: String) throws -> TranscriptCheckpoint? {
        let url = fileURL(sha256: sha256)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let checkpoint = try decoder.decode(TranscriptCheckpoint.self, from: data)
        try checkpoint.validate()
        let repaired = try checkpoint.repairingCaptions()
        guard repaired != checkpoint else { return checkpoint }
        let backup = directory.appendingPathComponent("\(sha256).before-caption-v2.json")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: backup.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else { throw CocoaError(.fileWriteFileExists) }
        } else {
            try data.write(to: backup, options: [.atomic])
        }
        try save(repaired)
        return repaired
    }

    /// Reconciliation and checkpoint encoding stay on the storage actor.
    func commit(raw: [RawSegment], chunkIndex: Int, to checkpoint: TranscriptCheckpoint,
                language: String?, usage: OpenRouterUsage? = nil) throws -> TranscriptCheckpoint
    {
        let next = try checkpoint.committing(chunkIndex: chunkIndex, raw: raw,
                                             detectedLanguage: language, cloudUsage: usage)
        try save(next)
        return next
    }

    func save(_ checkpoint: TranscriptCheckpoint) throws {
        try checkpoint.validate()
        try AppDirectories.ensureExists(directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(checkpoint)
        let destination = fileURL(sha256: checkpoint.audioSHA256)
        try data.write(to: destination, options: [.atomic])
    }

    func delete(sha256: String) throws {
        let url = fileURL(sha256: sha256)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(sha256: String) -> URL {
        directory.appendingPathComponent("\(sha256).json")
    }
}
