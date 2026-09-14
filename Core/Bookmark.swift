import Foundation

/// A playback bookmark belonging to one recording's audio-content identity.
/// Queries and mutations always carry that SHA-256; a different digest is a
/// different recording and must not share this set.
public struct Bookmark: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let audioSHA256: String
    public let time: TimeInterval
    public var label: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), audioSHA256: String, time: TimeInterval, label: String?,
                createdAt: Date = Date(), updatedAt: Date = Date())
    {
        self.id = id
        self.audioSHA256 = audioSHA256
        self.time = time
        self.label = Self.normalizedLabel(label)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func normalizedLabel(_ label: String?) -> String? {
        guard let label else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.count <= 80 { return trimmed }
        var prefix = String(trimmed.prefix(80))
        while prefix.last?.isWhitespace == true {
            prefix.removeLast()
        }
        return prefix.isEmpty ? nil : prefix
    }
}

/// Bookmarks for a single audio SHA-256, ordered by playback time.
public struct BookmarkSet: Codable, Equatable, Sendable {
    public enum BookmarkError: Error, Equatable {
        case digestMismatch
        case invalidDigest
        case invalidTime
        case invalidDuration
    }

    public static let timeMatchTolerance: TimeInterval = 0.05

    public let audioSHA256: String
    public private(set) var bookmarks: [Bookmark]

    public init(audioSHA256: String, bookmarks: [Bookmark] = []) throws {
        guard Self.isDigest(audioSHA256) else { throw BookmarkError.invalidDigest }
        self.audioSHA256 = audioSHA256
        self.bookmarks = bookmarks
        try validateMembership()
        sortInPlace()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let digest = try container.decode(String.self, forKey: .audioSHA256)
        let items = try container.decode([Bookmark].self, forKey: .bookmarks)
        try self.init(audioSHA256: digest, bookmarks: items)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(audioSHA256, forKey: .audioSHA256)
        try container.encode(bookmarks, forKey: .bookmarks)
    }

    private enum CodingKeys: String, CodingKey {
        case audioSHA256, bookmarks
    }

    public func bookmark(at time: TimeInterval) -> Bookmark? {
        bookmarks.first { abs($0.time - time) < Self.timeMatchTolerance }
    }

    /// Pins `time` if none exists nearby; otherwise removes that pin.
    public func toggling(sha256: String, time: TimeInterval, duration: TimeInterval, label: String?,
                         now: Date = Date()) throws -> BookmarkSet
    {
        try require(sha256: sha256)
        try Self.validate(time: time, duration: duration)
        if let existing = bookmark(at: time) {
            return removing(sha256: sha256, id: existing.id)
        }
        var next = self
        next.bookmarks.append(Bookmark(audioSHA256: audioSHA256, time: time, label: label, createdAt: now, updatedAt: now))
        next.sortInPlace()
        return next
    }

    public func removing(sha256: String, id: UUID) -> BookmarkSet {
        guard sha256 == audioSHA256 else { return self }
        var next = self
        next.bookmarks.removeAll { $0.id == id }
        return next
    }

    public func validated(againstDuration duration: TimeInterval) throws {
        try validateMembership()
        for bookmark in bookmarks {
            try Self.validate(time: bookmark.time, duration: duration)
        }
    }

    public static func validate(time: TimeInterval, duration: TimeInterval) throws {
        guard duration.isFinite, duration >= 0 else { throw BookmarkError.invalidDuration }
        guard time.isFinite, time >= 0, time <= duration else { throw BookmarkError.invalidTime }
    }

    public static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }

    private func require(sha256: String) throws {
        guard sha256 == audioSHA256 else { throw BookmarkError.digestMismatch }
    }

    private func validateMembership() throws {
        for bookmark in bookmarks where bookmark.audioSHA256 != audioSHA256 {
            throw BookmarkError.digestMismatch
        }
    }

    private mutating func sortInPlace() {
        bookmarks.sort {
            if $0.time != $1.time { return $0.time < $1.time }
            return $0.createdAt < $1.createdAt
        }
    }
}
