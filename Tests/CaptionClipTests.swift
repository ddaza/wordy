import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import WordyCore
#endif

private enum Clip14To20 {
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/clip-14-20")
    }

    static var audioURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("assets/asr-compare/clip_14-20.mp3")
    }

    static func loadGold() throws -> CaptionJobFixture {
        try JSONDecoder().decode(
            CaptionJobFixture.self,
            from: Data(contentsOf: directory.appendingPathComponent("gold.json")),
        )
    }

    static func loadCloud() throws -> CaptionJobFixture {
        try JSONDecoder().decode(
            CaptionJobFixture.self,
            from: Data(contentsOf: directory.appendingPathComponent("cloud-60-10.json")),
        )
    }

    static func openRouterKey() -> String? {
        if let value = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !value.isEmpty {
            return value
        }
        let env = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".env")
        guard let text = try? String(contentsOf: env, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let item = line.trimmingCharacters(in: .whitespaces)
            guard item.hasPrefix("OPENROUTER_API_KEY="), !item.hasPrefix("#") else { continue }
            let value = item.dropFirst("OPENROUTER_API_KEY=".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : String(value)
        }
        return nil
    }
}

struct CaptionClipTests {
    @Test func `recorded phrases retain local word order and unchanged captions are never shifted`() throws {
        let fixture = try Clip14To20.loadCloud()
        let committed = fixture.reconcile()
        for raw in fixture.rawByChunk.flatMap(\.self) {
            let local = committed.filter { $0.start < raw.end && $0.end > raw.start }
            var words = TranscriptCoverage.words(in: local).makeIterator()
            let retainedInOrder = TranscriptCoverage.normalizedWords(raw.text).allSatisfy { word in
                while let next = words.next() {
                    if next == word {
                        return true
                    }
                }
                return false
            }
            #expect(retainedInOrder, "A recorded phrase lost ordered words in its own source interval")
        }
        for caption in committed {
            let originals = fixture.rawByChunk.flatMap(\.self).filter {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == caption.text && $0.end == caption.end
            }
            if !originals.isEmpty {
                #expect(originals.contains { $0.start == caption.start }, "An unchanged caption moved away from its source time")
            }
        }
    }

    @Test func `clip 14-20 stitch keeps every word some section heard`() throws {
        let gold = try Clip14To20.loadGold()
        let fixture = try Clip14To20.loadCloud()
        let committed = fixture.reconcile()
        _ = try TranscriptTimeline(segments: committed)
        #expect(fixture.plan.count == fixture.chunks.count)
        #expect(gold.duration == fixture.duration)

        let heard = Set(TranscriptCoverage.words(in: fixture.rawByChunk.flatMap(\.self)))
        let kept = Set(TranscriptCoverage.words(in: committed))
        let dropped = heard.subtracting(kept).sorted()
        #expect(dropped.isEmpty, Comment(rawValue: "heard words dropped by stitch: \(dropped.joined(separator: " "))"))
    }

    @Test func `clip 14-20 gold windows overlap by the capture policy`() throws {
        let gold = try Clip14To20.loadGold()
        let policy = gold.policy
        #expect(gold.plan.count == gold.chunks.count)
        #expect(gold.plan.first?.audioStart == 0)
        #expect(gold.plan.dropLast().allSatisfy { $0.audioDuration == policy.chunkSeconds })
        for (previous, next) in zip(gold.plan, gold.plan.dropFirst()) {
            #expect(previous.ownedEnd == next.ownedStart)
            #expect(next.audioStart == previous.audioEnd - policy.overlapSeconds)
        }
        for (previous, next) in zip(gold.chunks, gold.chunks.dropFirst()) {
            let previousEnd = previous.raw.map(\.end).max() ?? 0
            let nextStart = next.raw.map(\.start).min() ?? .infinity
            #expect(nextStart <= previousEnd, "chunk \(next.index) should not leave a gap after chunk \(previous.index)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WORDY_RECORD_CLIP"] == "1"))
    func `record clip 14-20 through ChunkPlanner and OpenRouterSectionClient`() async throws {
        let audio = Clip14To20.audioURL
        let key = try #require(Clip14To20.openRouterKey())
        #expect(FileManager.default.fileExists(atPath: audio.path))
        let fixture = try await CaptionJobRecorder.recordOpenRouter(
            name: "clip-14-20-cloud-60-10",
            audioURL: audio,
            duration: 360,
            policy: .cloudDefault,
            gold: [],
            model: .whisperLargeV3,
            apiKey: key,
        )
        try CaptionJobRecorder.encode(fixture)
            .write(to: Clip14To20.directory.appendingPathComponent("cloud-60-10.json"))
        #expect(fixture.chunks.count == fixture.plan.count)
        #expect(fixture.rawByChunk.contains { !$0.isEmpty })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WORDY_RECORD_GOLD"] == "1"))
    func `record clip 14-20 gold through overlapping policy windows`() async throws {
        let audio = Clip14To20.audioURL
        let key = try #require(Clip14To20.openRouterKey())
        #expect(FileManager.default.fileExists(atPath: audio.path))
        let policy = ChunkPolicy.gold
        let fixture = try await CaptionJobRecorder.recordOpenRouter(
            name: "clip-14-20-gold-\(policy.label)",
            audioURL: audio,
            duration: 360,
            policy: policy,
            gold: [],
            model: .whisperLargeV3,
            apiKey: key,
        )
        try CaptionJobRecorder.encode(fixture)
            .write(to: Clip14To20.directory.appendingPathComponent("gold.json"))
        #expect(fixture.chunks.count == fixture.plan.count)
        #expect(fixture.plan.dropFirst().first?.audioStart == policy.chunkSeconds - policy.overlapSeconds)
        #expect(fixture.rawByChunk.contains { !$0.isEmpty })
    }
}
