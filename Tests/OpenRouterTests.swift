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
        let chunks = ChunkPlanner.plan(duration: 120, policy: .cloudDefault)
        let chunk = chunks[1]
        let first = [TranscriptSegment(start: chunk.ownedStart - 2, end: chunk.ownedStart + 2,
                                       text: "Review the important point")]
        let audioStart = chunk.audioStart
        let relativeStart = (chunk.ownedStart - 1) - audioStart
        let result = try OpenRouterTranscript.decode(
            Data("""
            {"text":"important point. Again again","segments":[
              {"start":\(relativeStart),"end":\(relativeStart + 4),"text":"important point. Again"},
              {"start":\(relativeStart + 6),"end":\(relativeStart + 7),"text":"again"}
            ]}
            """.utf8),
            audioStart: audioStart, audioDuration: chunk.audioDuration, sourceDuration: 120,
        )
        let committed = CloudCaptionReconciler.commit(raw: result.segments, for: chunk, isLast: false, after: first)
        #expect(committed.segments.map(\.text) == ["Again", "again"])
    }

    @Test func `cloud policy keeps upload windows inside the PCM size cap`() {
        let policy = ChunkPolicy.cloudDefault
        #expect(policy.maximumAudioSeconds <= 80)
        let plan = ChunkPlanner.plan(duration: 360, policy: policy)
        #expect(plan.allSatisfy { $0.audioDuration <= 80 })
        #expect(plan.count == 6) // 60 s owned on a 6-minute clip
        #expect(OpenRouterModel.whisperLargeV3.configuration.policy == policy)
    }

    @Test func `cloud reconciler keeps boundary phrases that start on an owned edge`() throws {
        // Simulates Whisper's ~30 s grid around a 60 s seam with only 3 s of
        // context: section 0 drops start==60, section 1 resumes at abs 87 and
        // would lose the intervening titles without enough leading overlap.
        let tight = try ChunkPolicy(chunkSeconds: 60, overlapSeconds: 3)
        let tightPlan = ChunkPlanner.plan(duration: 180, policy: tight)
        let dropped = CloudCaptionReconciler.commit(
            raw: [.init(start: 60, end: 90, text: "Zhang Zhongjing Shang Han Lun Articaria")],
            for: tightPlan[0], isLast: false, after: [],
        )
        #expect(dropped.segments.isEmpty)

        let cloudPlan = ChunkPlanner.plan(duration: 180, policy: .cloudDefault)
        // With 15 s lead-in, the same absolute phrase starts inside section 1's
        // owned range after section 0's owned end (50), and is committed there.
        var committed: [TranscriptSegment] = []
        for (index, chunk) in cloudPlan.enumerated() {
            let raw: [RawSegment] = [
                .init(start: 30, end: 50, text: "Earlier context about skin disease"),
                .init(start: 60, end: 90, text: "Zhang Zhongjing Shang Han Lun Articaria"),
                .init(start: 90, end: 120, text: "Cao Yuanfang continues the lecture"),
            ]
            let step = CloudCaptionReconciler.commit(raw: raw, for: chunk, isLast: index == cloudPlan.count - 1,
                                                     after: committed)
            if let replacement = step.replacingLastSegment {
                committed[committed.count - 1] = replacement
            }
            committed.append(contentsOf: step.segments)
        }
        let text = committed.map(\.text).joined(separator: " ")
        #expect(text.contains("Zhang Zhongjing"))
        #expect(text.contains("Shang Han Lun"))
        #expect(text.contains("Articaria"))
        #expect(text.contains("Cao Yuanfang"))
    }

    @Test func `cloud overlapping phrases keep new words without crushing the prior caption`() {
        let plan = ChunkPlanner.plan(duration: 360, policy: .cloudDefault)
        let first = CloudCaptionReconciler.commit(
            raw: [.init(start: 180, end: 210,
                        text: "Qianjin Fang is the formula, worth more than a thousand gold. So if you get it, yeah.")],
            for: plan[3], isLast: false, after: [],
        )
        // Prefix re-hear: next phrase starts with the committed ending, then new herbs.
        let second = CloudCaptionReconciler.commit(
            raw: [
                .init(start: 185, end: 215,
                      text: "So if you get it, yeah. such as Ren Shen, Tang Gui, Er Jiao, those."),
                .init(start: 215, end: 241,
                      text: "And goes to the Ming Dynasty, then there's one person is called Wang Ken Tang"),
            ],
            for: plan[4], isLast: false, after: first.segments,
        )
        #expect(second.replacingLastSegment == nil)
        let texts = (first.segments + second.segments).map(\.text)
        #expect(texts.count == 3)
        #expect(texts[0].contains("Qianjin Fang"))
        #expect(texts[1].contains("Ren Shen"))
        #expect(texts[1].contains("Tang Gui"))
        #expect(!texts[1].lowercased().hasPrefix("so if you get it"))
        #expect(texts[2].contains("Wang Ken Tang"))
        #expect(second.segments[0].start == first.segments[0].end)
        #expect(second.segments[1].start >= second.segments[0].end)
    }

    @Test func `cloud mid sentence re-hear does not erase later clauses via short word matches`() {
        let plan = ChunkPlanner.plan(duration: 360, policy: .cloudDefault)
        let first = CloudCaptionReconciler.commit(
            raw: [.init(start: 180, end: 210, text: "So if you get it, yeah.")],
            for: plan[3], isLast: false, after: [],
        )
        // "yeah" appears again after new herb names — must not drop Ren Shen.
        let second = CloudCaptionReconciler.commit(
            raw: [.init(start: 185, end: 220,
                        text: "such as Ren Shen, Tang Gui, Er Jiao, those yeah and goes to the Ming Dynasty")],
            for: plan[4], isLast: false, after: first.segments,
        )
        let text = second.segments.map(\.text).joined(separator: " ")
        #expect(text.contains("Ren Shen"))
        #expect(text.contains("Tang Gui"))
        #expect(text.contains("Ming Dynasty"))
    }

    @Test func `cloud contained phrase times never concatenate into word salad`() {
        let plan = ChunkPlanner.plan(duration: 120, policy: .cloudDefault)
        let step = CloudCaptionReconciler.commit(
            raw: [
                .init(start: 50, end: 80, text: "earliest medical expert on the leprosy"),
                .init(start: 50, end: 70, text: "Do you remember the king of herbs"),
            ],
            for: plan[1], isLast: false, after: [],
        )
        #expect(step.segments.count == 1)
        #expect(step.segments[0].text == "earliest medical expert on the leprosy")
        #expect(!step.segments[0].text.contains("Do you remember"))
    }

    @Test func `WAV uploads are bounded mono PCM with no time compression`() throws {
        let wav = try CloudAudioEncoding.wav([0, 1, -1])
        #expect(wav.count == 50)
        #expect(String(data: wav.prefix(4), encoding: .ascii) == "RIFF")
        #expect(Array(wav.suffix(6)) == [0, 0, 255, 127, 1, 128])
        #expect(throws: OpenRouterError.tooLarge) { try CloudAudioEncoding.wav([]) }
        #expect(throws: OpenRouterError.tooLarge) { try CloudAudioEncoding.wav([Float](repeating: 0, count: 80 * 16000 + 1)) }
        let plan = ChunkPlanner.plan(duration: 14400, policy: OpenRouterModel.whisperLargeV3.configuration.policy)
        #expect(plan.allSatisfy { $0.audioDuration < 80 || abs($0.audioDuration - 80) < 0.001 })
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
