import Foundation
import Observation
import os

/// Drives local transcription jobs one chunk at a time through the XPC worker.
/// Each chunk is reconciled, appended to the checkpoint, and persisted before
/// it is published, so a crash or quit recomputes at most the active chunk.
/// Only one inference job runs at a time; other lectures wait in a FIFO queue.
@MainActor @Observable
final class TranscriptionCoordinator {
    enum Status: Equatable {
        case identifying
        case waitingForModel
        case queued
        case running(chunkIndex: Int, chunkCount: Int)
        case paused
        case complete
        case failed(String)

        var isActive: Bool {
            if case .running = self { return true }
            return false
        }
    }

    struct Job: Identifiable {
        let id: UUID
        let audioURL: URL
        let duration: TimeInterval
        var sha256: String?
        var status: Status = .identifying
        var segments: [TranscriptSegment] = []
        var completedThrough: TimeInterval = 0
        var restoredFromCheckpoint = false
        var lastRealTimeFactor: Double?
        var modelID: String?

        var fractionComplete: Double { duration > 0 ? min(1, completedThrough / duration) : 0 }
    }

    private(set) var jobs: [UUID: Job] {
        didSet {
            for (id, job) in jobs where oldValue[id]?.status != job.status {
                logger.notice("Job \(id.uuidString.prefix(8), privacy: .public) → \(String(describing: job.status), privacy: .public)")
            }
        }
    }
    var onSegmentsChanged: ((UUID, [TranscriptSegment], String?) -> Void)?

    let worker: WorkerClient
    let models: ModelManager
    var policy = ChunkPolicy.default
    var language = "auto"

    @ObservationIgnored private let store: CheckpointStore
    @ObservationIgnored private let logger = Logger(subsystem: "com.wordy.app", category: "coordinator")
    @ObservationIgnored private let monitor = ResponsivenessMonitor()
    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var activeLectureID: UUID?
    @ObservationIgnored private var activeJobID: UUID?
    @ObservationIgnored private var engineDescription: EngineDescription?

    init(worker: WorkerClient, models: ModelManager, store: CheckpointStore = CheckpointStore()) {
        self.worker = worker
        self.models = models
        self.store = store
        jobs = [:]
    }

    // MARK: - Public actions

    func register(lectureID: UUID, audioURL: URL, duration: TimeInterval) {
        guard jobs[lectureID] == nil else { return }
        jobs[lectureID] = Job(id: lectureID, audioURL: audioURL, duration: duration)
        Task { await identify(lectureID) }
    }

    func pause(lectureID: UUID) {
        if activeLectureID == lectureID {
            activeTask?.cancel()
            if let activeJobID { worker.cancel(jobID: activeJobID) }
        } else if let index = queue.firstIndex(of: lectureID) {
            queue.remove(at: index)
            jobs[lectureID]?.status = .paused
        }
    }

    func resume(lectureID: UUID) {
        guard let job = jobs[lectureID], job.sha256 != nil else { return }
        switch job.status {
        case .paused, .failed, .waitingForModel: enqueue(lectureID)
        default: break
        }
    }

    /// Called when a model finishes installing so waiting lectures can start.
    func modelBecameAvailable() {
        for (id, job) in jobs where job.status == .waitingForModel {
            enqueue(id)
        }
    }

    // MARK: - Identification and restore

    private func identify(_ lectureID: UUID) async {
        guard let job = jobs[lectureID] else { return }
        let url = job.audioURL
        let digest: String
        do {
            digest = try await Task.detached(priority: .utility) { try AudioContentDigest.sha256(of: url) }.value
        } catch {
            jobs[lectureID]?.status = .failed("The recording could not be read to identify it.")
            return
        }
        jobs[lectureID]?.sha256 = digest
        if let checkpoint = try? await store.load(sha256: digest) {
            let plan = ChunkPlanner.plan(duration: job.duration, policy: checkpoint.configuration.policy)
            jobs[lectureID]?.segments = checkpoint.segments
            jobs[lectureID]?.completedThrough = checkpoint.completedThrough(plan: plan)
            jobs[lectureID]?.restoredFromCheckpoint = true
            jobs[lectureID]?.modelID = checkpoint.configuration.modelID
            onSegmentsChanged?(lectureID, checkpoint.segments, digest)
            if checkpoint.isComplete {
                jobs[lectureID]?.status = .complete
                return
            }
        }
        enqueue(lectureID)
    }

    private func enqueue(_ lectureID: UUID) {
        guard models.readyModel != nil else {
            jobs[lectureID]?.status = .waitingForModel
            return
        }
        guard activeLectureID != lectureID, !queue.contains(lectureID) else { return }
        jobs[lectureID]?.status = .queued
        queue.append(lectureID)
        processQueue()
    }

    private func processQueue() {
        guard activeTask == nil, !queue.isEmpty else { return }
        let lectureID = queue.removeFirst()
        activeLectureID = lectureID
        activeTask = Task {
            await run(lectureID)
            activeTask = nil
            activeLectureID = nil
            activeJobID = nil
            processQueue()
        }
    }

    // MARK: - Job execution

    private func run(_ lectureID: UUID) async {
        guard let job = jobs[lectureID], let digest = job.sha256 else { return }
        guard let model = models.readyModel, let modelURL = models.installedURL(for: model) else {
            jobs[lectureID]?.status = .waitingForModel
            return
        }
        do {
            let engine = try await describeEngine()
            let configuration = TranscriptionConfiguration(
                engineName: engine.engineName, engineVersion: engine.engineVersion, modelID: model.id,
                language: language, policy: policy,
            )
            let plan = ChunkPlanner.plan(duration: job.duration, policy: policy)
            var checkpoint: TranscriptCheckpoint
            if let existing = try await store.load(sha256: digest),
               existing.matches(audioSHA256: digest, sourceDuration: job.duration, configuration: configuration,
                                chunkCount: plan.count)
            {
                checkpoint = existing
            } else {
                checkpoint = TranscriptCheckpoint(audioSHA256: digest, sourceDuration: job.duration,
                                                  configuration: configuration, chunkCount: plan.count)
                try await store.save(checkpoint)
                publish(lectureID, checkpoint: checkpoint, plan: plan)
            }
            jobs[lectureID]?.modelID = model.id

            let jobID = UUID()
            activeJobID = jobID
            var chunkRecords: [BenchmarkRecord.Chunk] = []
            var peakFootprint: UInt64 = 0
            var modelLoad = 0.0
            var firstResult: Double?
            let started = ContinuousClock.now
            monitor.start()
            defer { monitor.stop() }

            while let index = checkpoint.nextChunkIndex {
                if Task.isCancelled {
                    jobs[lectureID]?.status = .paused
                    return
                }
                let chunk = plan[index]
                jobs[lectureID]?.status = .running(chunkIndex: index, chunkCount: plan.count)
                let request = try ChunkTranscriptionRequest(
                    jobID: jobID, chunk: chunk, audioURL: job.audioURL, modelURL: modelURL, modelID: model.id,
                    language: language,
                )
                let result = try await transcribeWithRetry(request)
                let committed = ChunkReconciler.commit(raw: result.segments, for: chunk,
                                                       isLast: index == plan.count - 1, after: checkpoint.segments)
                checkpoint = try checkpoint.committing(chunkIndex: index, segments: committed,
                                                       detectedLanguage: result.detectedLanguage)
                try await store.save(checkpoint)
                publish(lectureID, checkpoint: checkpoint, plan: plan)

                jobs[lectureID]?.lastRealTimeFactor = result.metrics.realTimeFactor
                modelLoad += result.metrics.modelLoadMilliseconds
                peakFootprint = max(peakFootprint, result.metrics.workerFootprintBytes)
                if firstResult == nil, !committed.isEmpty {
                    firstResult = (ContinuousClock.now - started).milliseconds
                }
                chunkRecords.append(.init(
                    index: index, audioSeconds: result.metrics.audioSeconds,
                    decodeMilliseconds: result.metrics.decodeMilliseconds,
                    inferenceMilliseconds: result.metrics.inferenceMilliseconds,
                    committedSegments: committed.count, footprintBytes: result.metrics.workerFootprintBytes,
                ))
            }
            jobs[lectureID]?.status = .complete
            let responsiveness = monitor.stop()
            if !chunkRecords.isEmpty {
                writeBenchmark(job: job, digest: digest, engine: engine, model: model, chunks: chunkRecords,
                               modelLoad: modelLoad, firstResult: firstResult, peak: peakFootprint,
                               wall: (ContinuousClock.now - started).milliseconds, segments: checkpoint.segments.count,
                               responsiveness: responsiveness)
            }
        } catch is CancellationError {
            jobs[lectureID]?.status = .paused
        } catch let error as WorkerClient.WorkerError where error == .failure(TranscriptionProtocol.cancelledMessage) {
            jobs[lectureID]?.status = .paused
        } catch {
            if Task.isCancelled {
                jobs[lectureID]?.status = .paused
            } else {
                logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                jobs[lectureID]?.status = .failed(error.localizedDescription)
            }
        }
    }

    /// The worker is relaunched automatically after a crash; the interrupted
    /// chunk is simply requested again because nothing uncommitted is lost.
    private func transcribeWithRetry(_ request: ChunkTranscriptionRequest) async throws -> ChunkTranscriptionResult {
        var attempt = 0
        while true {
            do {
                return try await worker.transcribe(request)
            } catch let error as WorkerClient.WorkerError where error == .interrupted && attempt < 2 && !Task.isCancelled {
                attempt += 1
                logger.warning("Worker interrupted during chunk \(request.chunkIndex); retry \(attempt)")
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func publish(_ lectureID: UUID, checkpoint: TranscriptCheckpoint, plan: [AudioChunk]) {
        jobs[lectureID]?.segments = checkpoint.segments
        jobs[lectureID]?.completedThrough = checkpoint.completedThrough(plan: plan)
        onSegmentsChanged?(lectureID, checkpoint.segments, checkpoint.audioSHA256)
    }

    private func describeEngine() async throws -> EngineDescription {
        if let engineDescription { return engineDescription }
        let description = try await worker.describeEngine()
        engineDescription = description
        return description
    }

    private func writeBenchmark(job: Job, digest: String, engine: EngineDescription, model: SpeechModel,
                                chunks: [BenchmarkRecord.Chunk], modelLoad: Double, firstResult: Double?,
                                peak: UInt64, wall: Double, segments: Int, responsiveness: (max: Double, p95: Double)?)
    {
        let processed = chunks.reduce(0) { $0 + $1.audioSeconds }
        let record = BenchmarkRecord(
            recordedAt: Date(), source: "Wordy.app via XPC worker", hardware: HostDescription.hardware(),
            operatingSystem: HostDescription.operatingSystem(), buildConfiguration: buildConfiguration,
            engineName: engine.engineName, engineVersion: engine.engineVersion, systemInfo: engine.systemInfo,
            gpuRequested: true, threads: 0, modelID: model.id, policy: policy.label, language: language,
            audioSHA256: digest, sourceDuration: job.duration, processedSeconds: processed,
            modelLoadMilliseconds: modelLoad, firstResultMilliseconds: firstResult ?? -1, wallMilliseconds: wall,
            realTimeFactor: processed > 0 ? wall / 1000 / processed : 0, peakFootprintBytes: peak,
            segmentCount: segments, mainThreadMaxDelayMilliseconds: responsiveness?.max,
            mainThreadP95DelayMilliseconds: responsiveness?.p95,
            notes: job.restoredFromCheckpoint ? "Resumed from checkpoint; wall time covers this session only." : nil,
            chunks: chunks,
        )
        let base = "app_\(model.id)_\(policy.label)_\(BenchmarkRecord.fileStamp(record.recordedAt))"
        do {
            let url = try BenchmarkRecord.write(record, to: AppDirectories.benchmarks, baseName: base)
            logger.info("Benchmark record written: \(url.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("Benchmark record failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var buildConfiguration: String {
        #if DEBUG
            "Debug"
        #else
            "Release"
        #endif
    }
}
