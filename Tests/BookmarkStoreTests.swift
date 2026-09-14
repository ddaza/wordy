#if !SWIFT_PACKAGE
    import Foundation
    import Testing

    struct BookmarkStoreTests {
        @Test func `bookmark edits persist on disk without losing concurrent pins`() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let digest = String(repeating: "a", count: 64)
            let store = BookmarkStore(directory: directory)
            let initial = try await store.update(sha256: digest) {
                try $0.toggling(sha256: digest, time: 12.3456789, duration: 7200, label: "Original")
            }
            let original = try #require(initial.bookmarks.first)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try await store.update(sha256: digest) {
                        try $0.renaming(sha256: digest, id: original.id, label: "My edited text")
                    }
                }
                for index in 1 ... 20 {
                    group.addTask {
                        _ = try await store.update(sha256: digest) {
                            try $0.toggling(sha256: digest, time: Double(index * 100), duration: 7200, label: "Another pin")
                        }
                    }
                }
                try await group.waitForAll()
            }
            let reopened = BookmarkStore(directory: directory)
            let saved = try await reopened.load(sha256: digest)
            #expect(saved.bookmarks.count == 21)
            let edited = try #require(saved.bookmarks.first(where: { $0.id == original.id }))
            #expect(edited.time == original.time)
            #expect(edited.audioSHA256 == original.audioSHA256)
            #expect(edited.label == "My edited text")
        }

        @Test @MainActor func `editing cannot mutate a bookmark from a different open recording`() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let digest = String(repeating: "a", count: 64)
            let otherDigest = String(repeating: "b", count: 64)
            let store = BookmarkStore(directory: directory)
            let initial = try await store.update(sha256: digest) {
                try $0.toggling(sha256: digest, time: 42.125, duration: 7200, label: "Original")
            }
            let bookmark = try #require(initial.bookmarks.first)
            let controller = BookmarkController(store: store)
            controller.display(sha256: digest, duration: 7200)
            try await controller.rename(bookmark, label: "Updated")
            #expect(controller.items.first?.time == bookmark.time)
            #expect(controller.items.first?.label == "Updated")
            controller.display(sha256: otherDigest, duration: 7200)
            do {
                try await controller.rename(bookmark, label: "Wrong recording")
                Issue.record("A foreign recording's bookmark was editable")
            } catch {
                #expect(error as? BookmarkSet.BookmarkError == .digestMismatch)
            }
            #expect(controller.items.isEmpty)
            #expect(try await store.load(sha256: digest).bookmarks.first?.label == "Updated")
            #expect(try await store.load(sha256: otherDigest).bookmarks.isEmpty)
        }
    }
#endif
