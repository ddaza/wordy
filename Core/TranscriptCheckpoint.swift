import Foundation

/// Identity of the engine configuration used for one transcript generation.
/// Any change means results are not comparable and a new generation starts.
public struct TranscriptionConfiguration: Codable, Hashable, Sendable {
    public let engineName: String
    public let engineVersion: String
    public let modelID: String
    public let language: String
    public let policy: ChunkPolicy

    public init(engineName: String, engineVersion: String, modelID: String, language: String, policy: ChunkPolicy) {
        self.engineName = engineName
        self.engineVersion = engineVersion
        self.modelID = modelID
        self.language = language
        self.policy = policy
    }
}

/// Durable record of committed transcript work for one recording, keyed by the
/// recording's audio-content SHA-256. Chunks are committed in order, so the
/// checkpoint only needs the count of committed chunks. Milestone 1 stores this
/// as an atomically replaced JSON document; Milestone 2 moves it into GRDB with
/// the same invariants.
public struct TranscriptCheckpoint: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public enum CheckpointError: Error, Equatable {
        case unsupportedFormat(Int)
        case chunkOutOfOrder(expected: Int, received: Int)
        case invalidSegments
    }

    public let format: Int
    public let audioSHA256: String
    public let sourceDuration: TimeInterval
    public let configuration: TranscriptionConfiguration
    public let chunkCount: Int
    public private(set) var committedChunkCount: Int
    public private(set) var segments: [TranscriptSegment]
    /// Per-section engine output, already on the source timeline. Index matches
    /// committed chunks. Older documents omit this; stitching still uses `segments`.
    public private(set) var raw: [[RawSegment]]?
    public private(set) var rawIsComplete: Bool?
    public private(set) var captionRevision: Int?
    public private(set) var pendingSegments: [TranscriptSegment]?
    public private(set) var detectedLanguage: String?
    public private(set) var updatedAt: Date
    public private(set) var cloudUsage: CloudUsageTotals?

    public init(audioSHA256: String, sourceDuration: TimeInterval, configuration: TranscriptionConfiguration,
                chunkCount: Int, now: Date = Date())
    {
        format = Self.currentFormat
        self.audioSHA256 = audioSHA256
        self.sourceDuration = sourceDuration
        self.configuration = configuration
        self.chunkCount = chunkCount
        committedChunkCount = 0
        segments = []
        raw = []
        rawIsComplete = true
        captionRevision = ChunkReconciler.revision
        pendingSegments = []
        detectedLanguage = nil
        updatedAt = now
    }

    public var isComplete: Bool {
        committedChunkCount >= chunkCount
    }

    public var nextChunkIndex: Int? {
        isComplete ? nil : committedChunkCount
    }

    /// Source time through which results are final.
    public func completedThrough(plan: [AudioChunk]) -> TimeInterval {
        guard committedChunkCount > 0, committedChunkCount <= plan.count else { return isComplete ? sourceDuration : 0 }
        if captionRevision == ChunkReconciler.revision {
            guard !isComplete else { return sourceDuration }
            guard plan.indices.contains(committedChunkCount) else { return 0 }
            return min(max(0, plan[committedChunkCount].audioStart - 0.25), pendingSegments?.first?.start ?? sourceDuration)
        }
        return plan[committedChunkCount - 1].ownedEnd
    }

    public func matches(audioSHA256: String, sourceDuration: TimeInterval, configuration: TranscriptionConfiguration,
                        chunkCount: Int) -> Bool
    {
        format == Self.currentFormat && self.audioSHA256 == audioSHA256
            && abs(self.sourceDuration - sourceDuration) < 0.05
            && self.configuration == configuration && self.chunkCount == chunkCount
    }

    /// Appends one chunk's committed segments. Callers persist the returned value
    /// before requesting the next chunk so a crash recomputes at most one chunk.
    public func committing(chunkIndex: Int, segments newSegments: [TranscriptSegment], detectedLanguage: String?,
                           now: Date = Date(), cloudUsage: OpenRouterUsage? = nil,
                           raw newRaw: [RawSegment]? = nil) throws -> TranscriptCheckpoint
    {
        guard pendingSegments?.isEmpty != false else { throw CheckpointError.invalidSegments }
        guard chunkIndex == committedChunkCount else {
            throw CheckpointError.chunkOutOfOrder(expected: committedChunkCount, received: chunkIndex)
        }
        let merged = segments + newSegments
        _ = try TranscriptTimeline(segments: merged)
        var next = self
        // Legacy/pre-reconciled import path. Raw omission is not recorded as
        // known silence, and must never authorize rebuilding these captions.
        next.captionRevision = nil
        next.pendingSegments = nil
        next.rawIsComplete = rawIsComplete == true && newRaw != nil
        next.segments = merged
        var collected = raw ?? []
        if collected.count < chunkIndex {
            collected.append(contentsOf: Array(repeating: [], count: chunkIndex - collected.count))
        }
        collected.append(newRaw ?? [])
        next.raw = collected
        next.committedChunkCount += 1
        if configuration.engineName == "OpenRouter" {
            next.cloudUsage = (self.cloudUsage ?? CloudUsageTotals(unreportedSections: committedChunkCount)).adding(cloudUsage)
        }
        next.updatedAt = now
        if next.detectedLanguage == nil {
            next.detectedLanguage = detectedLanguage
        }
        return next
    }

    /// Save one engine response and its revised boundary together. The caller
    /// executes this off the main actor and persists before publishing.
    public func committing(chunkIndex: Int, raw newRaw: [RawSegment], detectedLanguage: String?,
                           now: Date = Date(), cloudUsage: OpenRouterUsage? = nil) throws -> TranscriptCheckpoint
    {
        try validate()
        guard chunkIndex == committedChunkCount else {
            throw CheckpointError.chunkOutOfOrder(expected: committedChunkCount, received: chunkIndex)
        }
        let plan = ChunkPlanner.plan(duration: sourceDuration, policy: configuration.policy)
        guard plan.count == chunkCount, plan.indices.contains(chunkIndex) else { throw CheckpointError.invalidSegments }
        guard Self.validRaw(newRaw, for: plan[chunkIndex]) else { throw CheckpointError.invalidSegments }
        var state = CaptionPipeline.State(committed: segments, pending: pendingSegments ?? [])
        state.append(raw: newRaw, chunk: plan[chunkIndex], next: plan.indices.contains(chunkIndex + 1) ? plan[chunkIndex + 1] : nil)
        var next = self
        next.segments = state.committed
        next.pendingSegments = state.pending
        next.captionRevision = ChunkReconciler.revision
        next.rawIsComplete = hasReplayableRaw
        var collected = raw ?? []
        if collected.count < chunkIndex {
            collected.append(contentsOf: Array(repeating: [], count: chunkIndex - collected.count))
        }
        collected.append(newRaw)
        next.raw = collected
        next.committedChunkCount += 1
        next.updatedAt = now
        if next.detectedLanguage == nil {
            next.detectedLanguage = detectedLanguage
        }
        if configuration.engineName == "OpenRouter" {
            next.cloudUsage = cloudUsageTotals.adding(cloudUsage)
        }
        try next.validate()
        return next
    }

    private var cloudUsageTotals: CloudUsageTotals {
        cloudUsage ?? CloudUsageTotals(unreportedSections: committedChunkCount)
    }

    /// Old documents padded missing raw with empty lists. Without an explicit
    /// completeness flag, any empty list is ambiguous; leave those jobs intact.
    public var hasReplayableRaw: Bool {
        guard let raw, raw.count == committedChunkCount else { return false }
        return rawIsComplete ?? raw.allSatisfy { !$0.isEmpty }
    }

    public func repairingCaptions() throws -> TranscriptCheckpoint {
        guard (captionRevision ?? 0) < ChunkReconciler.revision, hasReplayableRaw, let raw else { return self }
        let plan = ChunkPlanner.plan(duration: sourceDuration, policy: configuration.policy)
        guard plan.count == chunkCount, raw.count <= plan.count,
              raw.enumerated().allSatisfy({ Self.validRaw($0.element, for: plan[$0.offset]) })
        else { return self }
        let state = CaptionPipeline.state(plan: plan, rawByChunk: raw)
        // Keep identities of unchanged passages across a local repair.
        struct Key: Hashable { let start: Double; let end: Double; let text: String }
        var identities: [Key: [UUID]] = [:]
        for segment in segments + (pendingSegments ?? []) {
            identities[Key(start: segment.start, end: segment.end, text: segment.text), default: []].append(segment.id)
        }
        func restore(_ segment: TranscriptSegment) -> TranscriptSegment {
            let key = Key(start: segment.start, end: segment.end, text: segment.text)
            guard var ids = identities[key], !ids.isEmpty else { return segment }
            let id = ids.removeFirst()
            identities[key] = ids
            return .init(id: id, start: segment.start, end: segment.end, text: segment.text,
                         timingUncertain: segment.timingUncertain == true)
        }
        var repaired = self
        repaired.segments = state.committed.map(restore)
        repaired.pendingSegments = state.pending.map(restore)
        repaired.rawIsComplete = true
        repaired.captionRevision = ChunkReconciler.revision
        try repaired.validate()
        return repaired
    }

    public func validate() throws {
        guard format == Self.currentFormat else { throw CheckpointError.unsupportedFormat(format) }
        guard sourceDuration.isFinite, sourceDuration > 0,
              (try? ChunkPolicy(chunkSeconds: configuration.policy.chunkSeconds,
                                overlapSeconds: configuration.policy.overlapSeconds)) != nil
        else { throw CheckpointError.invalidSegments }
        guard committedChunkCount >= 0, committedChunkCount <= chunkCount else { throw CheckpointError.invalidSegments }
        do { _ = try TranscriptTimeline(segments: segments + (pendingSegments ?? [])) } catch { throw CheckpointError.invalidSegments }
        if isComplete, !(pendingSegments ?? []).isEmpty {
            throw CheckpointError.invalidSegments
        }
        if rawIsComplete == true, raw?.count != committedChunkCount {
            throw CheckpointError.invalidSegments
        }
    }

    private static func validRaw(_ raw: [RawSegment], for chunk: AudioChunk) -> Bool {
        raw.allSatisfy {
            $0.start.isFinite && $0.end.isFinite && $0.start >= max(0, chunk.audioStart - 0.25)
                && $0.end > $0.start && $0.start < chunk.audioEnd && $0.end <= chunk.audioEnd + 0.25
        }
    }
}
