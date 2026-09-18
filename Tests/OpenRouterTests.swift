import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import WordyCore
#endif

struct OpenRouterTests {
    @Test func `cloud timestamps retain the decoded source offset and silence gaps`() throws {
        let data = Data(#"{"text":"Hello again","language":"en","segments":[{"start":2,"end":4,"text":"Hello"},{"start":9,"end":12,"text":"again"}]}"#.utf8)
        let result = try OpenRouterTranscript.decode(data, audioStart: 57.025, audioDuration: 66, sourceDuration: 7200)
        #expect(result.segments.map(\.start) == [59.025, 66.025])
        #expect(result.segments.map(\.end) == [61.025, 69.025])
        #expect(result.language == "en")
    }

    @Test func `text without caption timestamps is never committed as silence`() throws {
        for text in [#"{"text":"Some words"}"#, #"{"text":"Some words","segments":[]}"#,
                     #"{"text":"Some words","segments":[{"start":0,"end":1,"text":" "}]}"#]
        {
            #expect(throws: OpenRouterError.missingTimestamps) {
                try OpenRouterTranscript.decode(Data(text.utf8), audioStart: 0, audioDuration: 60, sourceDuration: 60)
            }
        }
        let silence = try OpenRouterTranscript.decode(Data(#"{"text":"","segments":[]}"#.utf8),
                                                      audioStart: 60, audioDuration: 60, sourceDuration: 120)
        #expect(silence.segments.isEmpty)
    }

    @Test func `invalid cloud timing fails the section instead of silently dropping speech`() {
        for segment in [#"{"start":-1,"end":1,"text":"A"}"#, #"{"start":5,"end":4,"text":"A"}"#,
                        #"{"start":0,"end":90,"text":"A"}"#, #"{"start":60,"end":61,"text":"A"}"#]
        {
            let data = Data("{\"text\":\"A\",\"segments\":[\(segment)]}".utf8)
            #expect(throws: OpenRouterError.invalidResponse) {
                try OpenRouterTranscript.decode(data, audioStart: 0, audioDuration: 60, sourceDuration: 60)
            }
        }
        #expect(throws: OpenRouterError.invalidResponse) {
            try OpenRouterTranscript.decode(Data("bad json".utf8), audioStart: 0, audioDuration: 60, sourceDuration: 60)
        }
    }

    @Test func `cloud phrase overlap preserves deliberate repetition`() throws {
        let chunks = ChunkPlanner.plan(duration: 120, policy: .default)
        let first = [TranscriptSegment(start: 56, end: 62, text: "Review the important point")]
        let result = try OpenRouterTranscript.decode(
            Data(#"{"text":"important point. Again again","segments":[{"start":3,"end":7,"text":"important point. Again"},{"start":9,"end":10,"text":"again"}]}"#.utf8),
            audioStart: 57, audioDuration: 63, sourceDuration: 120,
        )
        let committed = ChunkReconciler.commit(raw: result.segments, for: chunks[1], isLast: true, after: first)
        #expect(committed.map(\.text) == ["Again", "again"])
        #expect(committed.map(\.start) == [62, 66])
    }

    @Test func `WAV uploads are bounded mono PCM with no time compression`() throws {
        let wav = try CloudAudioEncoding.wav([0, 1, -1])
        #expect(wav.count == 50)
        #expect(String(data: wav.prefix(4), encoding: .ascii) == "RIFF")
        #expect(Array(wav.suffix(6)) == [0, 0, 255, 127, 1, 128])
        #expect(throws: OpenRouterError.tooLarge) { try CloudAudioEncoding.wav([]) }
        #expect(throws: OpenRouterError.tooLarge) { try CloudAudioEncoding.wav([Float](repeating: 0, count: 80 * 16000 + 1)) }
        let plan = ChunkPlanner.plan(duration: 14400, policy: OpenRouterModel.whisperLargeV3.configuration.policy)
        #expect(plan.allSatisfy { $0.audioDuration < 80 })
    }

    @Test func `cloud generations cannot be mistaken for local checkpoints`() {
        let config = OpenRouterModel.whisperLargeV3.configuration
        let checkpoint = TranscriptCheckpoint(audioSHA256: "a", sourceDuration: 120, configuration: config, chunkCount: 2)
        let local = TranscriptionConfiguration(engineName: "whisper.cpp", engineVersion: "1", modelID: config.modelID,
                                               language: "auto", policy: .default)
        #expect(!checkpoint.matches(audioSHA256: "a", sourceDuration: 120, configuration: local, chunkCount: 2))
        #expect(!checkpoint.matches(audioSHA256: "b", sourceDuration: 120, configuration: config, chunkCount: 2))
    }
}
