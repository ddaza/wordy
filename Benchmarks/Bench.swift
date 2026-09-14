import AVFoundation
import Foundation

/// wordy-bench: runs the same decode → whisper → reconcile pipeline the app
/// uses, in-process, and writes a benchmark record plus the transcript text.
///
/// Usage:
///   wordy-bench --audio FILE --model FILE --model-id ID [--chunk 60] [--overlap 3]
///               [--language auto] [--threads 0] [--no-gpu] [--limit SECONDS]
///               [--output DIR]
struct Options {
    var audio: URL?
    var model: URL?
    var modelID = "unknown"
    var chunkSeconds = 60.0
    var overlapSeconds = 3.0
    var language = "auto"
    var threads = 0
    var useGPU = true
    var limitSeconds: Double?
    var output = URL(fileURLWithPath: "build/benchmarks")

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var iterator = arguments.dropFirst().makeIterator()
        func value(_ flag: String) throws -> String {
            guard let next = iterator.next() else { throw UsageError("\(flag) needs a value") }
            return next
        }
        while let argument = iterator.next() {
            switch argument {
            case "--audio": options.audio = URL(fileURLWithPath: try value(argument))
            case "--model": options.model = URL(fileURLWithPath: try value(argument))
            case "--model-id": options.modelID = try value(argument)
            case "--chunk": options.chunkSeconds = Double(try value(argument)) ?? options.chunkSeconds
            case "--overlap": options.overlapSeconds = Double(try value(argument)) ?? options.overlapSeconds
            case "--language": options.language = try value(argument)
            case "--threads": options.threads = Int(try value(argument)) ?? 0
            case "--no-gpu": options.useGPU = false
            case "--limit": options.limitSeconds = Double(try value(argument))
            case "--output": options.output = URL(fileURLWithPath: try value(argument))
            default: throw UsageError("Unknown argument \(argument)")
            }
        }
        guard options.audio != nil, options.model != nil else {
            throw UsageError("--audio and --model are required")
        }
        return options
    }
}

struct UsageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

@main
enum Bench {
    static func main() async {
        do {
            try await run(Options.parse(CommandLine.arguments))
        } catch {
            log("error: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func run(_ options: Options) async throws {
        guard let audioURL = options.audio, let modelURL = options.model else { return }
        let policy = try ChunkPolicy(chunkSeconds: options.chunkSeconds, overlapSeconds: options.overlapSeconds)
        let asset = AVURLAsset(url: audioURL)
        let fullDuration = try await asset.load(.duration).seconds
        let duration = min(fullDuration, options.limitSeconds ?? fullDuration)
        let plan = ChunkPlanner.plan(duration: duration, policy: policy)
        let digest = try AudioContentDigest.sha256(of: audioURL)
        let session = InferenceSession()
        let description = session.describe()
        let jobID = UUID()
        let threads = options.threads > 0 ? options.threads : InferenceSession.defaultThreadCount

        log("wordy-bench · \(description.engineName) \(description.engineVersion) · model \(options.modelID) · policy \(policy.label) · gpu=\(options.useGPU) threads=\(threads)")
        log("audio \(String(format: "%.1f", duration)) s in \(plan.count) chunks · sha256 \(digest.prefix(12))…")

        var committed: [TranscriptSegment] = []
        var chunks: [BenchmarkRecord.Chunk] = []
        var peak: UInt64 = 0
        var modelLoad = 0.0
        var firstResult: Double?
        let started = ContinuousClock.now

        for chunk in plan {
            let request = try ChunkTranscriptionRequest(
                jobID: jobID, chunk: chunk, audioURL: audioURL, modelURL: modelURL, modelID: options.modelID,
                language: options.language, threads: threads, useGPU: options.useGPU,
            )
            let result = try await session.transcribe(request)
            let isLast = chunk.index == plan.count - 1
            let segments = ChunkReconciler.commit(raw: result.segments, for: chunk, isLast: isLast, after: committed)
            committed += segments
            _ = try TranscriptTimeline(segments: committed)
            modelLoad += result.metrics.modelLoadMilliseconds
            peak = max(peak, result.metrics.workerFootprintBytes)
            if firstResult == nil, !segments.isEmpty {
                firstResult = (ContinuousClock.now - started).milliseconds
            }
            chunks.append(.init(
                index: chunk.index, audioSeconds: result.metrics.audioSeconds,
                decodeMilliseconds: result.metrics.decodeMilliseconds,
                inferenceMilliseconds: result.metrics.inferenceMilliseconds,
                committedSegments: segments.count, footprintBytes: result.metrics.workerFootprintBytes,
            ))
            let elapsed = (ContinuousClock.now - started).milliseconds / 1000
            log(String(format: "chunk %3d/%d  %7.1fs owned  rtf %.3f  elapsed %6.1fs  footprint %5.0f MB",
                       chunk.index + 1, plan.count, chunk.ownedDuration, result.metrics.realTimeFactor, elapsed,
                       Double(result.metrics.workerFootprintBytes) / 1_048_576))
        }

        let wall = (ContinuousClock.now - started).milliseconds
        let record = BenchmarkRecord(
            recordedAt: Date(),
            source: "wordy-bench (in-process)",
            hardware: HostDescription.hardware(),
            operatingSystem: HostDescription.operatingSystem(),
            buildConfiguration: buildConfiguration,
            engineName: description.engineName,
            engineVersion: description.engineVersion,
            systemInfo: description.systemInfo,
            gpuRequested: options.useGPU,
            threads: threads,
            modelID: options.modelID,
            policy: policy.label,
            language: options.language,
            audioSHA256: digest,
            sourceDuration: fullDuration,
            processedSeconds: duration,
            modelLoadMilliseconds: modelLoad,
            firstResultMilliseconds: firstResult ?? -1,
            wallMilliseconds: wall,
            realTimeFactor: wall / 1000 / duration,
            peakFootprintBytes: peak,
            segmentCount: committed.count,
            chunks: chunks,
        )

        let base = "\(options.modelID)_\(policy.label)_\(options.useGPU ? "gpu" : "cpu")_\(BenchmarkRecord.fileStamp(record.recordedAt))"
        _ = try BenchmarkRecord.write(record, to: options.output, baseName: base)
        let transcript = committed.map { "[\(timestamp($0.start))] \($0.text)" }.joined(separator: "\n")
        try transcript.write(to: options.output.appendingPathComponent("\(base).txt"), atomically: true, encoding: .utf8)

        log(String(format: "done · wall %.1fs · rtf %.3f · first result %.1fs · peak footprint %.0f MB · %d segments",
                   wall / 1000, record.realTimeFactor, (firstResult ?? 0) / 1000, Double(peak) / 1_048_576, committed.count))
        log("wrote \(options.output.appendingPathComponent(base).path).{json,txt}")
    }

    static var buildConfiguration: String {
        #if DEBUG
            "Debug"
        #else
            "Release"
        #endif
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let value = Int(seconds)
        return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}
