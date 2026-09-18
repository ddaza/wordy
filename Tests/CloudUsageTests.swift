import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import WordyCore
#endif

struct CloudUsageTests {
    private func usage(_ json: String) throws -> OpenRouterUsage {
        try JSONDecoder().decode(OpenRouterUsage.self, from: Data(json.utf8))
    }

    @Test func `reported cost and tokens accumulate atomically with checkpointed sections`() throws {
        let first = try usage(#"{"cost":0.00045,"seconds":60,"input_tokens":100,"output_tokens":20,"total_tokens":120}"#)
        let second = try usage(#"{"cost":0.000495,"seconds":66,"input_tokens":110,"output_tokens":22}"#)
        var checkpoint = TranscriptCheckpoint(audioSHA256: "synthetic", sourceDuration: 180,
                                              configuration: OpenRouterModel.whisperLargeV3.configuration, chunkCount: 3)
        checkpoint = try checkpoint.committing(chunkIndex: 0, segments: [], detectedLanguage: nil, cloudUsage: first)
        let restored = try JSONDecoder().decode(TranscriptCheckpoint.self, from: JSONEncoder().encode(checkpoint))
        checkpoint = try restored.committing(chunkIndex: 1, segments: [], detectedLanguage: nil, cloudUsage: second)
        let total = try #require(checkpoint.cloudUsage)
        #expect(abs(total.costUSD - 0.000945) < 1e-10)
        #expect(total.totalTokens == 252)
        #expect(total.inputTokens == 210)
        #expect(total.outputTokens == 42)
        #expect(total.sections == 2 && total.costSections == 2 && total.tokenSections == 2)
        #expect(abs((total.lastSectionCostPerAudioHour ?? 0) - 0.027) < 1e-10)
        #expect(throws: TranscriptCheckpoint.CheckpointError.chunkOutOfOrder(expected: 2, received: 1)) {
            try checkpoint.committing(chunkIndex: 1, segments: [], detectedLanguage: nil, cloudUsage: second)
        }
    }

    @Test func `missing usage stays unknown and old checkpoints remain readable`() throws {
        var checkpoint = TranscriptCheckpoint(audioSHA256: "synthetic", sourceDuration: 180,
                                              configuration: OpenRouterModel.whisperLargeV3.configuration, chunkCount: 3)
        checkpoint = try checkpoint.committing(chunkIndex: 0, segments: [], detectedLanguage: nil)
        var document = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(checkpoint)) as? [String: Any])
        document.removeValue(forKey: "cloudUsage")
        let old = try JSONDecoder().decode(TranscriptCheckpoint.self, from: JSONSerialization.data(withJSONObject: document))
        #expect(old.cloudUsage == nil)
        let next = try old.committing(chunkIndex: 1, segments: [], detectedLanguage: nil,
                                      cloudUsage: usage(#"{"cost":0,"seconds":60}"#))
        let total = try #require(next.cloudUsage)
        #expect(total.costUSD == 0)
        #expect(total.costSections == 1 && total.sections == 2)
        #expect(total.tokenSections == 0)
        #expect(total.lastSectionCostPerAudioHour == 0)
        #expect(total.adding(nil).lastSectionCostPerAudioHour == nil)
    }

    @Test func `malformed usage never invents negative charges or loses valid captions`() throws {
        let bad = try usage(#"{"cost":-1,"total_tokens":-2,"input_tokens":1.5,"output_tokens":"bad","seconds":0}"#)
        #expect(bad.cost == nil && bad.totalTokens == nil && bad.inputTokens == nil && bad.outputTokens == nil)
        for billing in [#"{"cost":0.1,"total_tokens":12}"#, #""malformed""#, "null"] {
            let response = Data("{\"text\":\"Hello\",\"segments\":[{\"start\":0,\"end\":1,\"text\":\"Hello\"}],\"usage\":\(billing)}".utf8)
            let transcript = try OpenRouterTranscript.decode(response, audioStart: 0, audioDuration: 5, sourceDuration: 5)
            #expect(transcript.segments.first?.text == "Hello")
            if billing.hasPrefix("{") {
                #expect(transcript.usage?.totalTokens == 12)
            } else {
                #expect(transcript.usage == nil)
            }
        }
    }
}
