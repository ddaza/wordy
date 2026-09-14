import Foundation
import Testing
#if SWIFT_PACKAGE
    import WordyCore
#endif

private let digestA = String(repeating: "a", count: 64)
private let digestB = String(repeating: "b", count: 64)

@Test func `bookmarks stay partitioned by audio digest and reject foreign pins`() throws {
    var set = try BookmarkSet(audioSHA256: digestA)
    set = try set.toggling(sha256: digestA, time: 12, duration: 120, label: "  Opening remarks  ")
    #expect(set.bookmarks.count == 1)
    #expect(set.bookmarks[0].label == "Opening remarks")
    #expect(set.bookmark(at: 12.02) != nil)
    #expect(throws: BookmarkSet.BookmarkError.digestMismatch) {
        try set.toggling(sha256: digestB, time: 12, duration: 120, label: "other")
    }
    #expect(throws: BookmarkSet.BookmarkError.invalidDigest) {
        try BookmarkSet(audioSHA256: "short")
    }
    let foreign = Bookmark(audioSHA256: digestB, time: 5, label: "nope")
    #expect(throws: BookmarkSet.BookmarkError.digestMismatch) {
        try BookmarkSet(audioSHA256: digestA, bookmarks: [foreign])
    }
}

@Test func `bookmark times must sit inside the recording and toggling the same moment unpins`() throws {
    var set = try BookmarkSet(audioSHA256: digestA)
    #expect(throws: BookmarkSet.BookmarkError.invalidTime) {
        try set.toggling(sha256: digestA, time: -0.1, duration: 60, label: nil)
    }
    #expect(throws: BookmarkSet.BookmarkError.invalidTime) {
        try set.toggling(sha256: digestA, time: 60.1, duration: 60, label: nil)
    }
    #expect(throws: BookmarkSet.BookmarkError.invalidTime) {
        try set.toggling(sha256: digestA, time: .nan, duration: 60, label: nil)
    }
    set = try set.toggling(sha256: digestA, time: 0, duration: 60, label: "start")
    set = try set.toggling(sha256: digestA, time: 60, duration: 60, label: "end")
    #expect(set.bookmarks.map(\.time) == [0, 60])
    set = try set.toggling(sha256: digestA, time: 0, duration: 60, label: nil)
    #expect(set.bookmarks.count == 1)
    #expect(set.bookmarks[0].time == 60)
    let removed = set.removing(sha256: digestB, id: set.bookmarks[0].id)
    #expect(removed.bookmarks.count == 1)
    #expect(set.removing(sha256: digestA, id: set.bookmarks[0].id).bookmarks.isEmpty)
}

@Test func `bookmark labels truncate and empty labels are omitted`() {
    let long = String(repeating: "word ", count: 40)
    let bookmark = Bookmark(audioSHA256: digestA, time: 3, label: long)
    #expect((bookmark.label?.count ?? 0) <= 80)
    #expect(bookmark.label?.isEmpty == false)
    #expect(Bookmark(audioSHA256: digestA, time: 3, label: "   ").label == nil)
}

@Test func `bookmark sets round trip without mixing recordings`() throws {
    var set = try BookmarkSet(audioSHA256: digestA)
    set = try set.toggling(sha256: digestA, time: 8, duration: 90, label: "first")
    set = try set.toggling(sha256: digestA, time: 2, duration: 90, label: "earlier")
    #expect(set.bookmarks.map(\.time) == [2, 8])
    let data = try JSONEncoder().encode(set)
    let decoded = try JSONDecoder().decode(BookmarkSet.self, from: data)
    #expect(decoded == set)
    try decoded.validated(againstDuration: 90)
}

@Test func `editing bookmark text preserves its exact timestamp and identity`() throws {
    let created = Date(timeIntervalSince1970: 100)
    let edited = Date(timeIntervalSince1970: 200)
    var set = try BookmarkSet(audioSHA256: digestA)
    set = try set.toggling(sha256: digestA, time: 123.456789, duration: 7200, label: "Old transcript text", now: created)
    set = try set.toggling(sha256: digestA, time: 456, duration: 7200, label: "Other pin", now: created)
    let original = set.bookmarks[0]
    let renamed = try set.renaming(sha256: digestA, id: original.id, label: "  My own description  ", now: edited)
    let bookmark = renamed.bookmarks[0]
    #expect(bookmark.id == original.id)
    #expect(bookmark.audioSHA256 == original.audioSHA256)
    #expect(bookmark.time == original.time)
    #expect(bookmark.createdAt == original.createdAt)
    #expect(bookmark.updatedAt == edited)
    #expect(bookmark.label == "My own description")
    #expect(renamed.bookmarks[1] == set.bookmarks[1])
    let decoded = try JSONDecoder().decode(BookmarkSet.self, from: JSONEncoder().encode(renamed))
    #expect(decoded == renamed)
    #expect(throws: BookmarkSet.BookmarkError.digestMismatch) {
        try set.renaming(sha256: digestB, id: original.id, label: "Wrong recording")
    }
    #expect(try renamed.renaming(sha256: digestA, id: UUID(), label: "Deleted pin") == renamed)
    let cleared = try renamed.renaming(sha256: digestA, id: original.id, label: " \n ")
    #expect(cleared.bookmarks[0].label == nil)
    #expect(cleared.bookmarks[0].time == original.time)
    let shortened = try renamed.renaming(sha256: digestA, id: original.id, label: String(repeating: "a", count: 100))
    #expect(shortened.bookmarks[0].label?.count == 80)
}
