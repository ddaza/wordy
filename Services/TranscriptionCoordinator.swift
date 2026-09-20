import Foundation
import Observation
import os

/// Drives one local or explicitly consented cloud job at a time.
/// Each chunk is reconciled, appended to the checkpoint, and persisted before
/// it is published, so a crash or quit recomputes at most the active chunk.
/// Only one inference job runs at a time; other lectures wait in a FIFO queue.
@MainActor @Observable
final class TranscriptionCoordinator {
    enum Status: Equatable {
        case identifying
        case waitingForModel
        case waitingForCloudConsent
        case queued
        case running(chunkIndex: Int, chunkCount: Int)
        case paused
        case complete
        case failed(String)

        var isActive: Bool {
            if case .running = self {
                return true
            }
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
        var cloudUsage: CloudUsageTotals?
        var modelID: String?
        var requestedLocalModel: SpeechModel?
        var cloudRestartPending = false
        var cloudConfiguration: TranscriptionConfiguration?
        var isCloud: Bool {
            cloudConfiguration != nil
        }

        var modelDescription: String? {
            if let configuration = cloudConfiguration {
                let name = OpenRouterModel(rawValue: configuration.modelID)?.displayName ?? configuration.modelID
                return "\(name) · OpenRouter"
            }
            guard let id = modelID else { return nil }
            return "\(SpeechModelCatalog.model(id: id)?.displayName ?? id) · On this Mac"
        }

        var fractionComplete: Double {
            duration > 0 ? min(1, completedThrough / duration) : 0
        }
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
    let cloud: CloudSettings
    var policy = ChunkPolicy.default
    var language = "auto"

    @ObservationIgnored private let provider: any CloudTranscribing
    @ObservationIgnored private var pendingConsents: [UUID: CloudConsent] = [:]
    @ObservationIgnored private var cloudGrants: [UUID: CloudConsent] = [:]
    @ObservationIgnored private var switching: Set<UUID> = []
    @ObservationIgnored private let store: CheckpointStore
    @ObservationIgnored private let logger = Logger(subsystem: "com.wordy.app", category: "coordinator")
    @ObservationIgnored private let monitor = ResponsivenessMonitor()
    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var activeLectureID: UUID?
    @ObservationIgnored private var activeJobID: UUID?
    @ObservationIgnored private var engineDescription: EngineDescription?

    init(worker: WorkerClient, models: ModelManager, store: CheckpointStore = CheckpointStore(),
         cloud: CloudSettings = CloudSettings(), provider: any CloudTranscribing = OpenRouterProvider())
    {
        self.worker = worker
        self.models = models
        self.store = store
        self.cloud = cloud
        self.provider = provider
        jobs = [:]
        cloud.onSelectionChanged = { [weak self] in self?.selectionChanged() }
        cloud.onAuthorizationRevoked = { [weak self] in self?.revokeCloudAuthorization() }
    }

    var selectedModelDescription: String {
        if cloud.usesCloud {
            return "\(cloud.model.displayName) · OpenRouter"
        }
        return models.readyModel.map { "\($0.displayName) · On this Mac" } ?? "No local model selected"
    }

    func useLocalModel(_ model: SpeechModel) {
        cloud.useLocal()
        models.select(model)
        modelBecameAvailable()
    }

    private func selectionChanged() {
        for (id, job) in jobs where job.status == .waitingForModel || job.status == .waitingForCloudConsent {
            if cloud.usesCloud {
                jobs[id]?.status = .waitingForCloudConsent
            } else {
                jobs[id]?.status = models.readyModel == nil ? .waitingForModel : .paused
            }
        }
    }

    enum RetranscriptionChoice {
        case local(SpeechModel?)
        case cloud(CloudConsent)
    }

    /// Snapshot the model displayed in the confirmation, including a fresh
    /// generation when retranscribing an incomplete cloud job.
    func prepareRetranscription(lectureID: UUID) -> RetranscriptionChoice? {
        guard jobs[lectureID]?.sha256 != nil, !switching.contains(lectureID) else { return nil }
        if cloud.usesCloud {
            return prepareCloudConsent(lectureID: lectureID, restarting: true).map { .cloud($0) }
        }
        return .local(models.readyModel)
    }

    // MARK: - Public actions

    func register(lectureID: UUID, audioURL: URL, duration: TimeInterval) {
        guard jobs[lectureID] == nil else { return }
        jobs[lectureID] = Job(id: lectureID, audioURL: audioURL, duration: duration)
        Task { await identify(lectureID) }
    }

    func pause(lectureID: UUID) {
        cloudGrants.removeValue(forKey: lectureID)
        if activeLectureID == lectureID {
            activeTask?.cancel()
            if let activeJobID {
                worker.cancel(jobID: activeJobID)
            }
        } else if let index = queue.firstIndex(of: lectureID) {
            queue.remove(at: index)
            jobs[lectureID]?.status = .paused
        }
    }

    func resume(lectureID: UUID) {
        guard let job = jobs[lectureID], job.sha256 != nil, !job.isCloud, !switching.contains(lectureID) else { return }
        switch job.status {
        case .paused, .failed, .waitingForModel: enqueue(lectureID)
        default: break
        }
    }

    /// Discards the committed checkpoint and transcribes again with the model
    /// currently in use. In-flight work for this lecture is cancelled first.
    func retranscribe(lectureID: UUID, model: SpeechModel) {
        guard !switching.contains(lectureID) else { return }
        switching.insert(lectureID)
        Task {
            defer { switching.remove(lectureID) }
            await performRetranscribe(lectureID, model: model)
        }
    }

    /// Called when a model finishes installing so waiting lectures can start.
    func modelBecameAvailable() {
        for (id, job) in jobs where job.status == .waitingForModel {
            enqueue(id)
        }
    }

    private func performRetranscribe(_ lectureID: UUID, model: SpeechModel) async {
        guard jobs[lectureID]?.sha256 != nil else { return }
        cloudGrants.removeValue(forKey: lectureID)
        pendingConsents.removeValue(forKey: lectureID)
        if activeLectureID == lectureID {
            let inFlight = activeTask
            inFlight?.cancel()
            if let activeJobID {
                worker.cancel(jobID: activeJobID)
            }
            await inFlight?.value
        } else if let index = queue.firstIndex(of: lectureID) {
            queue.remove(at: index)
        }
        guard let digest = jobs[lectureID]?.sha256 else { return }
        do {
            try await store.delete(sha256: digest)
        } catch {
            jobs[lectureID]?.status = .failed("The previous transcript could not be cleared.")
            return
        }
        jobs[lectureID]?.segments = []
        jobs[lectureID]?.completedThrough = 0
        jobs[lectureID]?.restoredFromCheckpoint = false
        jobs[lectureID]?.modelID = model.id
        jobs[lectureID]?.requestedLocalModel = model
        jobs[lectureID]?.cloudUsage = nil
        jobs[lectureID]?.cloudConfiguration = nil
        jobs[lectureID]?.cloudRestartPending = false
        jobs[lectureID]?.lastRealTimeFactor = nil
        onSegmentsChanged?(lectureID, [], digest)
        enqueue(lectureID)
    }

    /// Consent is a one-use snapshot of the recording and model displayed in the
    /// confirmation sheet. It is never persisted or recreated during restoration.
    struct CloudConsent: Identifiable, Equatable {
        let id: UUID
        let lectureID: UUID
        let digest: String
        let title: String
        let duration: Double
        let model: OpenRouterModel
        let restarting: Bool
    }

    func prepareCloudConsent(lectureID: UUID, restarting: Bool = false) -> CloudConsent? {
        guard cloud.isEnabled, !switching.contains(lectureID), let job = jobs[lectureID],
              let digest = job.sha256 else { return nil }
        if !restarting, job.isCloud, job.status.isActive || job.status == .queued {
            return nil
        }
        let resumeModel = !restarting && job.status != .complete
            ? job.cloudConfiguration.flatMap { OpenRouterModel(rawValue: $0.modelID) } : nil
        let consent = CloudConsent(id: UUID(), lectureID: lectureID, digest: digest,
                                   title: job.audioURL.deletingPathExtension().lastPathComponent, duration: job.duration,
                                   model: resumeModel ?? cloud.model, restarting: restarting || job.status == .complete || job.cloudRestartPending)
        pendingConsents[lectureID] = consent
        return consent
    }

    func startCloud(consent: CloudConsent) async -> Bool {
        cloud.message = nil
        let id = consent.lectureID
        guard pendingConsents[id] == consent, cloud.isEnabled, !switching.contains(id),
              jobs[id]?.sha256 == consent.digest else { return false }
        pendingConsents.removeValue(forKey: id)
        switching.insert(id)
        cloudGrants[id] = consent
        defer { switching.remove(id) }
        do {
            _ = try await cloud.authorizedKey()
            guard cloudGrants[id] == consent else { return false }
            if activeLectureID == id {
                let running = activeTask
                running?.cancel()
                if let activeJobID {
                    worker.cancel(jobID: activeJobID)
                }
                await running?.value
            } else {
                queue.removeAll { $0 == id }
            }
            guard cloud.isEnabled, cloudGrants[id] == consent, jobs[id]?.sha256 == consent.digest else { return false }
            jobs[id]?.requestedLocalModel = nil
            jobs[id]?.cloudConfiguration = consent.model.configuration
            jobs[id]?.cloudRestartPending = consent.restarting
            enqueue(id)
            return true
        } catch {
            cloudGrants.removeValue(forKey: id)
            cloud.message = (error as? OpenRouterError)?.localizedDescription
                ?? "Wordy could not access the API key in Keychain."
            return false
        }
    }

    private func revokeCloudAuthorization() {
        pendingConsents.removeAll()
        let ids = Array(cloudGrants.keys)
        cloudGrants.removeAll()
        for id in ids {
            pause(lectureID: id)
        }
    }

    private func runCloud(_ lectureID: UUID) async {
        guard let job = jobs[lectureID], let digest = job.sha256,
              let consent = cloudGrants[lectureID], cloud.isEnabled
        else {
            jobs[lectureID]?.status = .paused
            return
        }
        do {
            let (actualDigest, sourceVersion) = try await Task.detached(priority: .utility) {
                let before = try AudioSourceVersion.read(job.audioURL)
                let digest = try AudioContentDigest.sha256(of: job.audioURL)
                guard try AudioSourceVersion.read(job.audioURL) == before else { throw OpenRouterError.sourceChanged }
                return (digest, before)
            }.value
            try Task.checkCancellation()
            guard actualDigest == digest else { throw OpenRouterError.sourceChanged }
            let configuration = consent.model.configuration
            let plan = ChunkPlanner.plan(duration: job.duration, policy: configuration.policy)
            guard !plan.isEmpty else { throw OpenRouterError.invalidResponse }
            var checkpoint: TranscriptCheckpoint = if !consent.restarting, let existing = try await store.load(sha256: digest),
                                                      existing.matches(audioSHA256: digest, sourceDuration: job.duration,
                                                                       configuration: configuration, chunkCount: plan.count)
            {
                existing
            } else {
                TranscriptCheckpoint(audioSHA256: digest, sourceDuration: job.duration,
                                     configuration: configuration, chunkCount: plan.count)
            }
            jobs[lectureID]?.modelID = configuration.modelID
            jobs[lectureID]?.completedThrough = checkpoint.completedThrough(plan: plan)
            jobs[lectureID]?.cloudUsage = checkpoint.cloudUsage ?? (checkpoint.configuration.engineName == "OpenRouter"
                ? CloudUsageTotals(unreportedSections: checkpoint.committedChunkCount) : nil)
            jobs[lectureID]?.lastRealTimeFactor = nil
            // Preserve the old transcript on disk until the first cloud result
            // is safely saved. Merely confirming or failing auth loses no work.
            while let index = checkpoint.nextChunkIndex {
                try Task.checkCancellation()
                guard cloudGrants[lectureID] == consent, cloud.isEnabled else {
                    throw OpenRouterError.authorizationRequired
                }
                guard try await Task.detached(priority: .utility, operation: {
                    try AudioSourceVersion.read(job.audioURL)
                }).value == sourceVersion else { throw OpenRouterError.sourceChanged }
                let key = try await cloud.authorizedKey()
                try Task.checkCancellation()
                let chunk = plan[index]
                jobs[lectureID]?.status = .running(chunkIndex: index, chunkCount: plan.count)
                let started = ContinuousClock.now
                let result = try await provider.transcribe(audioURL: job.audioURL, chunk: chunk,
                                                           sourceDuration: job.duration, model: consent.model, apiKey: key)
                guard try await Task.detached(priority: .utility, operation: {
                    try AudioSourceVersion.read(job.audioURL)
                }).value == sourceVersion else { throw OpenRouterError.sourceChanged }
                // Save an already completed response even if pause arrived just
                // after it, so resuming does not bill that section a second time.
                do {
                    checkpoint = try await store.commit(raw: result.segments, chunkIndex: index, to: checkpoint,
                                                        language: result.language, usage: result.usage)
                } catch { throw OpenRouterError.storage }
                jobs[lectureID]?.cloudRestartPending = false
                jobs[lectureID]?.restoredFromCheckpoint = false
                jobs[lectureID]?.lastRealTimeFactor = (ContinuousClock.now - started).milliseconds / 1000 / chunk.audioDuration
                publish(lectureID, checkpoint: checkpoint, plan: plan)
            }
            publish(lectureID, checkpoint: checkpoint, plan: plan)
            jobs[lectureID]?.status = .complete
        } catch is CancellationError {
            jobs[lectureID]?.status = .paused
        } catch {
            jobs[lectureID]?.status = Task.isCancelled ? .paused : .failed(
                (error as? OpenRouterError)?.localizedDescription ?? "Cloud transcription stopped. Check the recording and Keychain, then try again.",
            )
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
        let restored: TranscriptCheckpoint?
        do { restored = try await store.load(sha256: digest) }
        catch {
            jobs[lectureID]?.status = .failed("The saved transcript could not be restored. Check available disk space and reopen the recording.")
            return
        }
        if let checkpoint = restored {
            let plan = ChunkPlanner.plan(duration: job.duration, policy: checkpoint.configuration.policy)
            jobs[lectureID]?.cloudUsage = checkpoint.cloudUsage ?? (checkpoint.configuration.engineName == "OpenRouter"
                ? CloudUsageTotals(unreportedSections: checkpoint.committedChunkCount) : nil)
            jobs[lectureID]?.segments = checkpoint.segments
            jobs[lectureID]?.completedThrough = checkpoint.completedThrough(plan: plan)
            jobs[lectureID]?.restoredFromCheckpoint = true
            jobs[lectureID]?.modelID = checkpoint.configuration.modelID
            if checkpoint.configuration.engineName == "OpenRouter" {
                jobs[lectureID]?.cloudConfiguration = checkpoint.configuration
            }
            onSegmentsChanged?(lectureID, checkpoint.segments, digest)
            if checkpoint.isComplete {
                jobs[lectureID]?.status = .complete
                return
            }
            if jobs[lectureID]?.isCloud == true {
                jobs[lectureID]?.status = .paused
                return
            }
        }
        enqueue(lectureID)
    }

    private func enqueue(_ lectureID: UUID) {
        if cloud.usesCloud, jobs[lectureID]?.isCloud != true, jobs[lectureID]?.requestedLocalModel == nil {
            jobs[lectureID]?.status = .waitingForCloudConsent
            return
        }
        if jobs[lectureID]?.isCloud == true {
            guard cloud.isEnabled, cloudGrants[lectureID] != nil else {
                jobs[lectureID]?.status = .paused
                return
            }
        }
        if jobs[lectureID]?.isCloud != true {
            guard let model = jobs[lectureID]?.requestedLocalModel ?? models.readyModel,
                  models.installedURL(for: model) != nil
            else {
                jobs[lectureID]?.status = .waitingForModel
                return
            }
            jobs[lectureID]?.requestedLocalModel = model
            jobs[lectureID]?.modelID = model.id
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
        if jobs[lectureID]?.isCloud == true {
            let grant = cloudGrants[lectureID]
            await runCloud(lectureID)
            if cloudGrants[lectureID] == grant {
                cloudGrants.removeValue(forKey: lectureID)
            }
            return
        }
        guard let job = jobs[lectureID], let digest = job.sha256 else { return }
        guard let model = job.requestedLocalModel ?? models.readyModel, let modelURL = models.installedURL(for: model) else {
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
                let previousCount = checkpoint.segments.count
                checkpoint = try await store.commit(raw: result.segments, chunkIndex: index, to: checkpoint,
                                                    language: result.detectedLanguage)
                let committedCount = max(0, checkpoint.segments.count - previousCount)
                publish(lectureID, checkpoint: checkpoint, plan: plan)

                jobs[lectureID]?.lastRealTimeFactor = result.metrics.realTimeFactor
                modelLoad += result.metrics.modelLoadMilliseconds
                peakFootprint = max(peakFootprint, result.metrics.workerFootprintBytes)
                if firstResult == nil, committedCount > 0 {
                    firstResult = (ContinuousClock.now - started).milliseconds
                }
                chunkRecords.append(.init(
                    index: index, audioSeconds: result.metrics.audioSeconds,
                    decodeMilliseconds: result.metrics.decodeMilliseconds,
                    inferenceMilliseconds: result.metrics.inferenceMilliseconds,
                    committedSegments: committedCount, footprintBytes: result.metrics.workerFootprintBytes,
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
        jobs[lectureID]?.cloudUsage = checkpoint.cloudUsage ?? (checkpoint.configuration.engineName == "OpenRouter"
            ? CloudUsageTotals(unreportedSections: checkpoint.committedChunkCount) : nil)
        jobs[lectureID]?.segments = checkpoint.segments
        jobs[lectureID]?.completedThrough = checkpoint.completedThrough(plan: plan)
        onSegmentsChanged?(lectureID, checkpoint.segments, checkpoint.audioSHA256)
    }

    private func describeEngine() async throws -> EngineDescription {
        if let engineDescription {
            return engineDescription
        }
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
