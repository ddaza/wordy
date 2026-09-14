import Foundation
import os

/// One inference worker per process. Blocking decode and `whisper_full` run on
/// a dedicated serial utility-QoS queue so playback and UI in the app process
/// keep priority. The loaded model is reused across chunks and released after
/// an idle interval.
final class InferenceSession: @unchecked Sendable {
    static let idleUnloadInterval: TimeInterval = 300

    private let queue = DispatchQueue(label: "com.wordy.inference", qos: .utility)
    private let logger = Logger(subsystem: "com.wordy.app", category: "inference")
    private let lock = NSLock()
    private var activeJobs: [String: CancellationFlag] = [:]
    // Queue-confined state.
    private var engine: WhisperEngine?
    private var idleUnload: DispatchWorkItem?

    func describe() -> EngineDescription {
        EngineDescription(
            engineName: WhisperEngine.engineName,
            engineVersion: WhisperEngine.engineVersion,
            systemInfo: WhisperEngine.systemInfo,
            gpuAvailable: WhisperEngine.gpuCompiledIn,
        )
    }

    func cancel(jobID: String) {
        lock.withLock { activeJobs[jobID] }?.cancel()
    }

    func unloadModel() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                engine = nil
                continuation.resume()
            }
        }
    }

    func transcribe(_ request: ChunkTranscriptionRequest) async throws -> ChunkTranscriptionResult {
        try request.validate()
        let flag = CancellationFlag()
        let jobKey = request.jobID.uuidString
        lock.withLock { activeJobs[jobKey] = flag }
        defer {
            lock.withLock {
                if activeJobs[jobKey] === flag {
                    activeJobs[jobKey] = nil
                }
            }
        }

        let source = try await AudioChunkDecoder.prepare(url: URL(fileURLWithPath: request.audioPath))
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try continuation.resume(returning: run(request, source: source, cancellation: flag))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Queue-confined work

    private func run(_ request: ChunkTranscriptionRequest, source: PreparedAudioSource,
                     cancellation: CancellationFlag) throws -> ChunkTranscriptionResult
    {
        idleUnload?.cancel()
        defer { scheduleIdleUnload() }
        if cancellation.isCancelled {
            throw WhisperEngineError.cancelled
        }

        var loadMilliseconds = 0.0
        if engine?.modelPath != request.modelPath || engine?.useGPU != (request.useGPU && WhisperEngine.gpuCompiledIn) {
            engine = nil
            let loaded = try WhisperEngine(modelPath: request.modelPath, useGPU: request.useGPU)
            loadMilliseconds = loaded.loadMilliseconds
            engine = loaded
            logger.info("Loaded model \(request.modelID, privacy: .public) in \(loadMilliseconds, privacy: .public) ms")
        }
        guard let engine else { throw WhisperEngineError.modelLoadFailed }

        let decodeStart = ContinuousClock.now
        let audio = try AudioChunkDecoder.decode(source, start: request.audioStart, end: request.audioEnd,
                                                 isCancelled: { cancellation.isCancelled })
        let decodeMilliseconds = (ContinuousClock.now - decodeStart).milliseconds

        let inferenceStart = ContinuousClock.now
        let threads = request.threads > 0 ? request.threads : Self.defaultThreadCount
        let output = try engine.transcribe(samples: audio.samples, language: request.language, threads: threads,
                                           cancellation: cancellation)
        let inferenceMilliseconds = (ContinuousClock.now - inferenceStart).milliseconds

        let segments = output.segments.map { segment in
            RawSegment(start: audio.startTime + segment.start, end: audio.startTime + segment.end,
                       text: segment.text, noSpeechProbability: segment.noSpeechProbability)
        }
        return ChunkTranscriptionResult(
            jobID: request.jobID,
            chunkIndex: request.chunkIndex,
            segments: segments,
            detectedLanguage: output.language,
            engineVersion: WhisperEngine.engineVersion,
            modelID: request.modelID,
            metrics: ChunkMetrics(
                audioSeconds: audio.duration,
                decodeMilliseconds: decodeMilliseconds,
                modelLoadMilliseconds: loadMilliseconds,
                inferenceMilliseconds: inferenceMilliseconds,
                workerFootprintBytes: ProcessFootprint.current(),
            ),
        )
    }

    private func scheduleIdleUnload() {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            engine = nil
            logger.info("Unloaded idle speech model")
        }
        idleUnload = item
        queue.asyncAfter(deadline: .now() + Self.idleUnloadInterval, execute: item)
    }

    /// Roughly one thread per performance core: 4 on an 8-core M1, 4 on a
    /// quad-core hyper-threaded Intel Mac, capped so efficiency cores and the
    /// UI process are not starved.
    static var defaultThreadCount: Int {
        max(1, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))
    }
}
