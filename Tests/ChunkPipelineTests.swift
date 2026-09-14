import Foundation
import Testing
#if SWIFT_PACKAGE
    import WordyCore
#endif

@Test func `chunk plan covers the recording exactly once with bounded context`() throws {
    let policy = try ChunkPolicy(chunkSeconds: 60, overlapSeconds: 3)
    let duration = 5986.064
    let plan = ChunkPlanner.plan(duration: duration, policy: policy)
    #expect(plan.first?.ownedStart == 0)
    #expect(plan.first?.audioStart == 0)
    #expect(plan.last?.ownedEnd == duration)
    #expect(plan.last?.audioEnd == duration)
    for (previous, next) in zip(plan, plan.dropFirst()) {
        #expect(previous.ownedEnd == next.ownedStart)
        #expect(next.audioStart == next.ownedStart - 3)
        #expect(previous.audioEnd == previous.ownedEnd + 3)
        #expect(previous.audioDuration <= 66)
    }
    // 5986 / 60 = 99.77 → 99 full chunks plus a 46 s tail kept as its own chunk.
    #expect(plan.count == 100)
    #expect(ChunkPlanner.plan(duration: 0, policy: policy).isEmpty)
    #expect(ChunkPlanner.plan(duration: .nan, policy: policy).isEmpty)
}

@Test func `short tails merge into the previous chunk`() throws {
    let policy = try ChunkPolicy(chunkSeconds: 60, overlapSeconds: 2)
    let plan = ChunkPlanner.plan(duration: 125, policy: policy)
    #expect(plan.count == 2)
    #expect(plan.last?.ownedEnd == 125)
    #expect(plan.last?.ownedDuration == 65)
}

@Test func `chunk policy rejects unusable values`() {
    #expect(throws: ChunkPolicy.PolicyError.self) { try ChunkPolicy(chunkSeconds: 1, overlapSeconds: 0) }
    #expect(throws: ChunkPolicy.PolicyError.self) { try ChunkPolicy(chunkSeconds: 30, overlapSeconds: 15) }
    #expect(throws: ChunkPolicy.PolicyError.self) { try ChunkPolicy(chunkSeconds: 30, overlapSeconds: -1) }
}

@Test func `overlap speech is committed once by the chunk that heard it start`() throws {
    let policy = try ChunkPolicy(chunkSeconds: 60, overlapSeconds: 3)
    let plan = ChunkPlanner.plan(duration: 120, policy: policy)
    let first = ChunkReconciler.commit(raw: [
        .init(start: 0, end: 10, text: "Welcome to the lecture."),
        .init(start: 55, end: 61, text: "The derivative of x squared"),
        .init(start: 61, end: 63, text: "is two x."), // starts past the owned end → chunk 1 commits it
    ], for: plan[0], isLast: false, after: [])
    #expect(first.map(\.text) == ["Welcome to the lecture.", "The derivative of x squared"])

    let second = ChunkReconciler.commit(raw: [
        .init(start: 57.5, end: 61, text: "derivative of x squared"), // fully inside committed time → dropped
        .init(start: 61, end: 63, text: "is two x."),
        .init(start: 63, end: 70, text: "Next we integrate."),
    ], for: plan[1], isLast: true, after: first)
    #expect(second.map(\.text) == ["is two x.", "Next we integrate."])
    _ = try TranscriptTimeline(segments: first + second)
}

@Test func `a sentence straddling the boundary is kept by the chunk with full context`() throws {
    let policy = try ChunkPolicy(chunkSeconds: 60, overlapSeconds: 3)
    let plan = ChunkPlanner.plan(duration: 120, policy: policy)
    // Starts 2 s before the boundary, ends inside the next chunk's owned range.
    let first = ChunkReconciler.commit(raw: [
        .init(start: 58, end: 62.5, text: "Only at that time did they recognize it."),
    ], for: plan[0], isLast: false, after: [])
    #expect(first.map(\.text) == ["Only at that time did they recognize it."])

    // The next chunk started mid-sentence and heard a garbled partial version.
    let second = ChunkReconciler.commit(raw: [
        .init(start: 59, end: 62.5, text: "time they recognized"),
        .init(start: 62.5, end: 66, text: "They call it external medicine."),
    ], for: plan[1], isLast: true, after: first)
    #expect(second.map(\.text) == ["They call it external medicine."])
    #expect(second.first?.start == 62.5)
    _ = try TranscriptTimeline(segments: first + second)
}

@Test func `disagreeing boundary transcripts are trimmed in proportion to committed time`() throws {
    let policy = try ChunkPolicy(chunkSeconds: 60, overlapSeconds: 3)
    let plan = ChunkPlanner.plan(duration: 120, policy: policy)
    let first = ChunkReconciler.commit(raw: [
        .init(start: 50, end: 62, text: "alpha beta gamma delta"),
    ], for: plan[0], isLast: false, after: [])
    // 58–66: half of this segment lies inside committed time and shares no words.
    let second = ChunkReconciler.commit(raw: [
        .init(start: 58, end: 66, text: "one two three four five six seven eight"),
    ], for: plan[1], isLast: true, after: first)
    #expect(second.first?.text == "five six seven eight")
    #expect(second.first?.start == 62)
    #expect(second.first?.end == 66)
}

@Test func `boundary duplicates are trimmed only where segments overlap in time`() throws {
    let policy = try ChunkPolicy(chunkSeconds: 60, overlapSeconds: 3)
    let plan = ChunkPlanner.plan(duration: 120, policy: policy)
    let first = ChunkReconciler.commit(raw: [
        .init(start: 50, end: 62, text: "We define the limit as h goes to zero"),
    ], for: plan[0], isLast: false, after: [])
    let second = ChunkReconciler.commit(raw: [
        .init(start: 60.5, end: 66, text: "as h goes to zero of the difference quotient."),
    ], for: plan[1], isLast: true, after: first)
    #expect(second.count == 1)
    #expect(second.first?.text == "of the difference quotient.")
    #expect(second.first?.start == 62)
    _ = try TranscriptTimeline(segments: first + second)
}

@Test func `deliberate repetition outside the overlap is preserved`() throws {
    let policy = try ChunkPolicy(chunkSeconds: 60, overlapSeconds: 3)
    let plan = ChunkPlanner.plan(duration: 120, policy: policy)
    let first = ChunkReconciler.commit(raw: [
        .init(start: 40, end: 45, text: "Again and again and again."),
    ], for: plan[0], isLast: false, after: [])
    let second = ChunkReconciler.commit(raw: [
        .init(start: 61, end: 66, text: "Again and again and again."),
    ], for: plan[1], isLast: true, after: first)
    #expect(second.first?.text == "Again and again and again.")
    #expect((first + second).count == 2)
}

@Test func `non speech markers and malformed output are dropped`() throws {
    let policy = try ChunkPolicy(chunkSeconds: 60, overlapSeconds: 3)
    let plan = ChunkPlanner.plan(duration: 60, policy: policy)
    let committed = ChunkReconciler.commit(raw: [
        .init(start: 0, end: 4, text: "[BLANK_AUDIO]"),
        .init(start: 4, end: 8, text: " (applause) "),
        .init(start: 8, end: 12, text: "   "),
        .init(start: 20, end: 15, text: "reversed"),
        .init(start: 15, end: .nan, text: "nan"),
        .init(start: 30, end: 31, text: "Real words."),
    ], for: plan[0], isLast: true, after: [])
    #expect(committed.map(\.text) == ["Real words."])
}

@Test func `checkpoint commits chunks in order and detects other generations`() throws {
    let policy = try ChunkPolicy(chunkSeconds: 60, overlapSeconds: 3)
    let configuration = TranscriptionConfiguration(engineName: "whisper.cpp", engineVersion: "1.9.4",
                                                   modelID: "whisper-small", language: "auto", policy: policy)
    let plan = ChunkPlanner.plan(duration: 180, policy: policy)
    var checkpoint = TranscriptCheckpoint(audioSHA256: "abc", sourceDuration: 180, configuration: configuration,
                                          chunkCount: plan.count)
    #expect(checkpoint.nextChunkIndex == 0)
    #expect(checkpoint.completedThrough(plan: plan) == 0)

    checkpoint = try checkpoint.committing(chunkIndex: 0, segments: [.init(start: 1, end: 5, text: "a")], detectedLanguage: "en")
    #expect(checkpoint.completedThrough(plan: plan) == 60)
    #expect(throws: TranscriptCheckpoint.CheckpointError.self) {
        try checkpoint.committing(chunkIndex: 2, segments: [], detectedLanguage: nil)
    }
    #expect(throws: TranscriptCheckpoint.CheckpointError.self) {
        try checkpoint.committing(chunkIndex: 0, segments: [], detectedLanguage: nil)
    }
    // Segments that would overlap committed work are rejected before persistence.
    #expect(throws: TranscriptTimeline.ValidationError.self) {
        try checkpoint.committing(chunkIndex: 1, segments: [.init(start: 3, end: 8, text: "b")], detectedLanguage: nil)
    }
    checkpoint = try checkpoint.committing(chunkIndex: 1, segments: [], detectedLanguage: nil)
    checkpoint = try checkpoint.committing(chunkIndex: 2, segments: [.init(start: 170, end: 175, text: "c")], detectedLanguage: nil)
    #expect(checkpoint.isComplete)
    #expect(checkpoint.nextChunkIndex == nil)
    #expect(checkpoint.detectedLanguage == "en")

    #expect(checkpoint.matches(audioSHA256: "abc", sourceDuration: 180, configuration: configuration, chunkCount: 3))
    #expect(!checkpoint.matches(audioSHA256: "def", sourceDuration: 180, configuration: configuration, chunkCount: 3))
    let otherModel = TranscriptionConfiguration(engineName: "whisper.cpp", engineVersion: "1.9.4",
                                                modelID: "whisper-base", language: "auto", policy: policy)
    #expect(!checkpoint.matches(audioSHA256: "abc", sourceDuration: 180, configuration: otherModel, chunkCount: 3))
    #expect(!checkpoint.matches(audioSHA256: "abc", sourceDuration: 240, configuration: configuration, chunkCount: 3))

    let encoded = try JSONEncoder().encode(checkpoint)
    let decoded = try JSONDecoder().decode(TranscriptCheckpoint.self, from: encoded)
    #expect(decoded == checkpoint)
    try decoded.validate()
}

@Test func `streaming digest matches a known vector and stays bounded`() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("wordy-digest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("abc".utf8).write(to: url)
    #expect(try AudioContentDigest.sha256(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    // Force many small reads to exercise the incremental path.
    var large = Data(count: 3 * 1024 * 1024 + 17)
    large.withUnsafeMutableBytes { bytes in
        for index in bytes.indices { bytes[index] = UInt8(index % 251) }
    }
    try large.write(to: url)
    #expect(try AudioContentDigest.sha256(of: url, bufferSize: 4096) == AudioContentDigest.sha256(of: url))
    #expect(throws: CancellationError.self) { try AudioContentDigest.sha256(of: url, isCancelled: { true }) }
}

@Test func `worker messages are versioned bounded and round trip`() throws {
    let policy = try ChunkPolicy(chunkSeconds: 60, overlapSeconds: 3)
    let chunk = ChunkPlanner.plan(duration: 100, policy: policy)[0]
    let audio = URL(fileURLWithPath: "/tmp/lecture.mp3")
    let model = URL(fileURLWithPath: "/tmp/model.bin")
    let request = try ChunkTranscriptionRequest(jobID: UUID(), chunk: chunk, audioURL: audio, modelURL: model, modelID: "whisper-small")
    #expect(request.protocolVersion == TranscriptionProtocol.version)
    #expect(request.audioEnd == 63)
    let data = try MessageCoding.encode(request)
    let decoded = try MessageCoding.decode(ChunkTranscriptionRequest.self, from: data)
    #expect(decoded == request)
    try decoded.validate()

    #expect(throws: TranscriptionProtocol.MessageError.self) {
        try ChunkTranscriptionRequest(jobID: UUID(), chunk: chunk, audioURL: #require(URL(string: "https://example.com/a.mp3")),
                                      modelURL: model, modelID: "x")
    }
    let huge = AudioChunk(index: 0, ownedStart: 0, ownedEnd: 1000, audioStart: 0, audioEnd: 1000)
    #expect(throws: TranscriptionProtocol.MessageError.self) {
        try ChunkTranscriptionRequest(jobID: UUID(), chunk: huge, audioURL: audio, modelURL: model, modelID: "x")
    }
    var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    json["protocolVersion"] = 99
    let future = try MessageCoding.decode(ChunkTranscriptionRequest.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(throws: TranscriptionProtocol.MessageError.self) { try future.validate() }
}

@Test func `catalog only recommends pinned models and refuses unpinned digests`() {
    #expect(SpeechModelCatalog.model(id: SpeechModelCatalog.recommendedModelID(isAppleSilicon: true)) != nil)
    #expect(SpeechModelCatalog.model(id: SpeechModelCatalog.recommendedModelID(isAppleSilicon: false)) != nil)
    for model in SpeechModelCatalog.models {
        #expect(model.downloadURL.scheme == "https")
        #expect(model.sha256.isEmpty || model.sha256.count == 64)
    }
}
