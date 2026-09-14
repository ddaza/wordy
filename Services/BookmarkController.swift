import Foundation
import Observation

/// In-memory bookmark list for the currently open recording. Every read and
/// write includes that recording's SHA-256; switching recordings replaces the
/// list immediately so another file's pins never stay on screen.
@MainActor @Observable
final class BookmarkController {
    private(set) var items: [Bookmark] = []
    private var digest: String?
    private var duration: TimeInterval = 0
    private var generation = 0
    private let store: BookmarkStore

    init(store: BookmarkStore = BookmarkStore()) {
        self.store = store
    }

    var canBookmark: Bool {
        digest != nil
    }

    func isBookmarked(time: TimeInterval) -> Bool {
        items.contains { abs($0.time - time) < BookmarkSet.timeMatchTolerance }
    }

    func display(sha256: String?, duration: TimeInterval) {
        generation += 1
        let generation = generation
        if sha256 != digest {
            items = []
        }
        digest = sha256
        self.duration = duration
        guard let sha256, BookmarkSet.isDigest(sha256) else { return }
        Task {
            let loaded = (try? await store.load(sha256: sha256))?.bookmarks ?? []
            guard generation == self.generation, self.digest == sha256 else { return }
            items = loaded.filter { (try? BookmarkSet.validate(time: $0.time, duration: duration)) != nil }
        }
    }

    func toggle(sha256: String, duration: TimeInterval, time: TimeInterval, label: String?) {
        guard digest == sha256, BookmarkSet.isDigest(sha256) else { return }
        generation += 1
        let generation = generation
        Task {
            do {
                var set = try await store.load(sha256: sha256)
                set = try set.toggling(sha256: sha256, time: time, duration: duration, label: label)
                try await store.save(set)
                guard generation == self.generation, self.digest == sha256 else { return }
                items = set.bookmarks
            } catch {
                return
            }
        }
    }

    func remove(_ bookmark: Bookmark) {
        guard digest == bookmark.audioSHA256 else { return }
        generation += 1
        let generation = generation
        let sha256 = bookmark.audioSHA256
        Task {
            do {
                var set = try await store.load(sha256: sha256)
                set = set.removing(sha256: sha256, id: bookmark.id)
                try await store.save(set)
                guard generation == self.generation, self.digest == sha256 else { return }
                items = set.bookmarks
            } catch {
                return
            }
        }
    }
}
