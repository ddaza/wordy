import Foundation

/// Application-managed storage under ~/Library/Application Support/Wordy.
/// Temporary downloads live beside their destination so they are never mistaken
/// for validated assets.
enum AppDirectories {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Wordy", isDirectory: true)
    }()

    static let models = root.appendingPathComponent("Models", isDirectory: true)
    static let transcripts = root.appendingPathComponent("Transcripts", isDirectory: true)
    static let bookmarks = root.appendingPathComponent("Bookmarks", isDirectory: true)
    static let benchmarks = root.appendingPathComponent("Benchmarks", isDirectory: true)

    static func ensureExists(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
