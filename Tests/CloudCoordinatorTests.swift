#if !SWIFT_PACKAGE
    import Foundation
    import Testing

    private actor MemoryCloudKeys: CloudKeyStoring {
        var key: String?
        var rejectsSaves = false
        func rejectSaves() {
            rejectsSaves = true
        }

        func read() -> String? {
            key
        }

        func save(_ key: String) throws {
            if rejectsSaves {
                throw OpenRouterError.missingKey
            }
            self.key = key
        }

        func delete() {
            key = nil
        }
    }

    private actor StubCloudProvider: CloudTranscribing {
        var indices: [Int] = []
        var models: [OpenRouterModel] = []
        var failingIndex: Int?
        var delayed = false
        func configure(failingIndex: Int? = nil, delayed: Bool = false) {
            self.failingIndex = failingIndex
            self.delayed = delayed
        }

        func transcribe(audioURL _: URL, chunk: AudioChunk, sourceDuration _: Double,
                        model: OpenRouterModel, apiKey _: String) async throws -> OpenRouterTranscript
        {
            indices.append(chunk.index)
            models.append(model)
            if delayed {
                try await Task.sleep(for: .seconds(30))
            }
            if chunk.index == failingIndex {
                throw OpenRouterError.network
            }
            return OpenRouterTranscript(segments: [.init(start: chunk.ownedStart, end: chunk.ownedStart + 2, text: "Synthetic passage")], language: "en")
        }
    }

    @MainActor
    private struct CloudFixture {
        let directory: URL
        let suite = "WordyTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        let audio: URL
        let digest: String
        let id = UUID()
        let keys = MemoryCloudKeys()
        let provider = StubCloudProvider()
        let settings: CloudSettings
        let store: CheckpointStore
        let coordinator: TranscriptionCoordinator
        let models: ModelManager

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            audio = directory.appendingPathComponent("synthetic.bin")
            try Data("Synthetic audio identity only; the provider is stubbed.".utf8).write(to: audio)
            digest = try AudioContentDigest.sha256(of: audio)
            defaults = UserDefaults(suiteName: suite)!
            settings = CloudSettings(defaults: defaults, keys: keys)
            store = CheckpointStore(directory: directory.appendingPathComponent("checkpoints"))
            models = ModelManager(directory: directory.appendingPathComponent("models"), defaults: defaults)
            coordinator = TranscriptionCoordinator(worker: WorkerClient(), models: models, store: store, cloud: settings, provider: provider)
        }

        func register(duration: Double = 120) async throws {
            coordinator.register(lectureID: id, audioURL: audio, duration: duration)
            try await eventually { coordinator.jobs[id]?.sha256 != nil && coordinator.jobs[id]?.status != .identifying }
        }

        func enable() async {
            settings.isEnabled = true
            await settings.saveKey("test-key")
        }

        func cleanup() {
            coordinator.pause(lectureID: id)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor
    private func eventually(_ predicate: () async -> Bool) async throws {
        for _ in 0 ..< 300 {
            if await predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for job state")
        throw CancellationError()
    }

    @MainActor
    struct CloudCoordinatorTests {
        @Test func `Use unlocks only after a successful key save and selection alone never uploads`() async throws {
            let f = try CloudFixture(); defer { f.cleanup() }
            f.settings.isEnabled = true
            #expect(!f.settings.canSelectModel)
            #expect(!f.settings.select(.whisperLargeV3Turbo))
            await f.settings.saveKey("test-key")
            #expect(f.settings.keySaveSucceeded)
            #expect(f.settings.hasKey && f.settings.canSelectModel)
            #expect(f.settings.message == "API key saved in Keychain.")
            #expect(f.settings.select(.whisperLargeV3Turbo))
            #expect(f.coordinator.selectedModelDescription == "Whisper Large V3 Turbo · OpenRouter")
            try await f.register()
            #expect(f.coordinator.jobs[f.id]?.status == .waitingForCloudConsent)
            f.coordinator.modelBecameAvailable()
            #expect(await f.provider.indices.isEmpty)
            let restored = CloudSettings(defaults: f.defaults, keys: f.keys)
            await restored.refresh()
            #expect(restored.usesCloud && restored.model == .whisperLargeV3Turbo)
            await f.settings.removeKey()
            #expect(!f.settings.usesCloud && !f.settings.canSelectModel)
            #expect(!f.settings.select(.whisperLargeV3))
        }

        @Test func `failed key save cannot enable cloud model selection`() async throws {
            let f = try CloudFixture(); defer { f.cleanup() }
            f.settings.isEnabled = true
            await f.keys.rejectSaves()
            await f.settings.saveKey("test-key")
            #expect(!f.settings.keySaveSucceeded && !f.settings.hasKey)
            #expect(!f.settings.canSelectModel)
            #expect(!f.settings.select(.whisperLargeV3))
            #expect(f.settings.message != nil)
        }

        @Test func `Transcribe Again snapshots the in-use cloud model and starts a new generation`() async throws {
            let f = try CloudFixture(); defer { f.cleanup() }
            var checkpoint = TranscriptCheckpoint(audioSHA256: f.digest, sourceDuration: 120,
                                                  configuration: OpenRouterModel.whisperLargeV3.configuration, chunkCount: 2)
            checkpoint = try checkpoint.committing(chunkIndex: 0, segments: [.init(start: 0, end: 2, text: "Previous")], detectedLanguage: nil)
            try await f.store.save(checkpoint)
            await f.enable()
            try await f.register()
            #expect(f.settings.select(.whisperLargeV3Turbo))
            guard case let .cloud(consent) = f.coordinator.prepareRetranscription(lectureID: f.id) else {
                Issue.record("Transcribe Again must use the cloud selection"); return
            }
            #expect(consent.model == .whisperLargeV3Turbo && consent.restarting)
            // Changing Settings while a confirmation is open cannot change its request.
            f.settings.select(.whisperLargeV3)
            #expect(await f.coordinator.startCloud(consent: consent))
            try await eventually { f.coordinator.jobs[f.id]?.status == .complete }
            #expect(await f.provider.indices == [0, 1])
            #expect(await f.provider.models == [.whisperLargeV3Turbo, .whisperLargeV3Turbo])
            #expect(f.coordinator.jobs[f.id]?.modelDescription == "Whisper Large V3 Turbo · OpenRouter")
            let local = f.models.recommended
            try FileManager.default.createDirectory(at: f.directory.appendingPathComponent("models"), withIntermediateDirectories: true)
            try Data().write(to: f.directory.appendingPathComponent("models").appendingPathComponent(local.fileName))
            f.coordinator.useLocalModel(local)
            guard case let .local(selected) = f.coordinator.prepareRetranscription(lectureID: f.id) else {
                Issue.record("Local Use must switch Transcribe Again back to local"); return
            }
            #expect(selected?.id == local.id)
            #expect(!f.settings.usesCloud)
        }

        @Test func `retranscribing an active cloud job retains the newly confirmed grant`() async throws {
            let f = try CloudFixture(); defer { f.cleanup() }
            await f.enable()
            await f.provider.configure(delayed: true)
            try await f.register()
            let initial = try #require(f.coordinator.prepareCloudConsent(lectureID: f.id))
            #expect(await f.coordinator.startCloud(consent: initial))
            try await eventually { await f.provider.indices.count == 1 }
            f.settings.select(.whisperLargeV3Turbo)
            guard case let .cloud(replacement) = f.coordinator.prepareRetranscription(lectureID: f.id) else {
                Issue.record("Expected a replacement cloud confirmation"); return
            }
            await f.provider.configure()
            #expect(await f.coordinator.startCloud(consent: replacement))
            try await eventually { f.coordinator.jobs[f.id]?.status == .complete }
            #expect(await f.provider.models == [.whisperLargeV3, .whisperLargeV3Turbo, .whisperLargeV3Turbo])
        }

        @Test func `cloud needs enabled settings a key and fresh per recording consent`() async throws {
            let f = try CloudFixture(); defer { f.cleanup() }
            try await f.register()
            #expect(!f.settings.isEnabled)
            #expect(f.coordinator.prepareCloudConsent(lectureID: f.id) == nil)
            f.settings.isEnabled = true
            let noKey = try #require(f.coordinator.prepareCloudConsent(lectureID: f.id))
            #expect(await f.coordinator.startCloud(consent: noKey) == false)
            #expect(await f.provider.indices.isEmpty)
            await f.settings.saveKey("test-key")
            f.coordinator.resume(lectureID: f.id)
            f.coordinator.modelBecameAvailable()
            #expect(await f.provider.indices.isEmpty)
            #expect(await f.coordinator.startCloud(consent: noKey) == false)
            let consent = try #require(f.coordinator.prepareCloudConsent(lectureID: f.id))
            f.settings.select(.whisperLargeV3Turbo)
            #expect(await f.coordinator.startCloud(consent: consent))
            #expect(await f.coordinator.startCloud(consent: consent) == false)
            try await eventually { f.coordinator.jobs[f.id]?.status == .complete }
            #expect(await f.provider.indices == [0, 1])
            #expect(await f.provider.models == [.whisperLargeV3, .whisperLargeV3])
        }

        @Test func `network failure preserves committed sections and never retries automatically`() async throws {
            let f = try CloudFixture(); defer { f.cleanup() }
            await f.enable()
            await f.provider.configure(failingIndex: 1)
            try await f.register(duration: 180)
            let consent = try #require(f.coordinator.prepareCloudConsent(lectureID: f.id))
            #expect(await f.coordinator.startCloud(consent: consent))
            try await eventually {
                if case .failed = f.coordinator.jobs[f.id]?.status {
                    return true
                }; return false
            }
            let saved = try #require(try await f.store.load(sha256: f.digest))
            #expect(saved.committedChunkCount == 1)
            #expect(await f.provider.indices == [0, 1])
            f.coordinator.resume(lectureID: f.id)
            #expect(await f.provider.indices == [0, 1])
            await f.provider.configure()
            let retry = try #require(f.coordinator.prepareCloudConsent(lectureID: f.id))
            #expect(await f.coordinator.startCloud(consent: retry))
            try await eventually { f.coordinator.jobs[f.id]?.status == .complete }
            #expect(await f.provider.indices == [0, 1, 1, 2])
            let complete = try #require(try await f.store.load(sha256: f.digest))
            #expect(complete.segments.first?.id == saved.segments.first?.id)
            #expect(complete.committedChunkCount == 3)
        }

        @Test func `relaunch restores cloud work paused without granting upload consent`() async throws {
            let f = try CloudFixture(); defer { f.cleanup() }
            var checkpoint = TranscriptCheckpoint(audioSHA256: f.digest, sourceDuration: 120,
                                                  configuration: OpenRouterModel.whisperLargeV3.configuration, chunkCount: 2)
            checkpoint = try checkpoint.committing(chunkIndex: 0, segments: [.init(start: 1, end: 2, text: "Saved")], detectedLanguage: "en")
            try await f.store.save(checkpoint)
            await f.enable()
            try await f.register()
            #expect(f.coordinator.jobs[f.id]?.status == .paused)
            #expect(f.coordinator.jobs[f.id]?.segments == checkpoint.segments)
            f.coordinator.resume(lectureID: f.id)
            f.coordinator.modelBecameAvailable()
            #expect(await f.provider.indices.isEmpty)
            let consent = try #require(f.coordinator.prepareCloudConsent(lectureID: f.id))
            #expect(await f.coordinator.startCloud(consent: consent))
            try await eventually { f.coordinator.jobs[f.id]?.status == .complete }
            #expect(await f.provider.indices == [1])
        }

        @Test func `disabling advanced mode cancels active uploads and invalidates consent`() async throws {
            let f = try CloudFixture(); defer { f.cleanup() }
            await f.enable()
            await f.provider.configure(delayed: true)
            try await f.register()
            let consent = try #require(f.coordinator.prepareCloudConsent(lectureID: f.id))
            #expect(await f.coordinator.startCloud(consent: consent))
            try await eventually { await f.provider.indices.count == 1 }
            f.settings.isEnabled = false
            try await eventually { f.coordinator.jobs[f.id]?.status == .paused }
            f.settings.isEnabled = true
            #expect(await f.coordinator.startCloud(consent: consent) == false)
            #expect(await f.provider.indices == [0])
            #expect(try await f.store.load(sha256: f.digest) == nil)
        }

        @Test func `changed source fails before sending any audio`() async throws {
            let f = try CloudFixture(); defer { f.cleanup() }
            await f.enable()
            try await f.register()
            let consent = try #require(f.coordinator.prepareCloudConsent(lectureID: f.id))
            try Data("Changed source".utf8).write(to: f.audio)
            #expect(await f.coordinator.startCloud(consent: consent))
            try await eventually {
                if case .failed = f.coordinator.jobs[f.id]?.status {
                    return true
                }; return false
            }
            #expect(await f.provider.indices.isEmpty)
            #expect(try await f.store.load(sha256: f.digest) == nil)
        }

        @Test func `failed replacement keeps the old transcript and retry starts the new generation`() async throws {
            let f = try CloudFixture(); defer { f.cleanup() }
            var previous = TranscriptCheckpoint(audioSHA256: f.digest, sourceDuration: 120,
                                                configuration: OpenRouterModel.whisperLargeV3.configuration, chunkCount: 2)
            previous = try previous.committing(chunkIndex: 0, segments: [.init(start: 1, end: 2, text: "Original")], detectedLanguage: "en")
            previous = try previous.committing(chunkIndex: 1, segments: [], detectedLanguage: "en")
            try await f.store.save(previous)
            await f.enable()
            await f.provider.configure(failingIndex: 0)
            try await f.register()
            let consent = try #require(f.coordinator.prepareCloudConsent(lectureID: f.id))
            #expect(consent.restarting)
            #expect(await f.coordinator.startCloud(consent: consent))
            try await eventually {
                if case .failed = f.coordinator.jobs[f.id]?.status {
                    return true
                }; return false
            }
            #expect(try await f.store.load(sha256: f.digest)?.segments == previous.segments)
            #expect(f.coordinator.jobs[f.id]?.segments == previous.segments)
            await f.provider.configure()
            let retry = try #require(f.coordinator.prepareCloudConsent(lectureID: f.id))
            #expect(retry.restarting)
            #expect(await f.coordinator.startCloud(consent: retry))
            try await eventually { f.coordinator.jobs[f.id]?.status == .complete }
            #expect(await f.provider.indices == [0, 0, 1])
            #expect(try await f.store.load(sha256: f.digest)?.segments != previous.segments)
        }

        @Test func `revoking consent cancels queued jobs as well as the active job`() async throws {
            let f = try CloudFixture(); defer { f.cleanup() }
            await f.enable()
            await f.provider.configure(delayed: true)
            try await f.register()
            let other = UUID()
            f.coordinator.register(lectureID: other, audioURL: f.audio, duration: 120)
            try await eventually { f.coordinator.jobs[other]?.status == .waitingForModel }
            let first = try #require(f.coordinator.prepareCloudConsent(lectureID: f.id))
            let second = try #require(f.coordinator.prepareCloudConsent(lectureID: other))
            #expect(await f.coordinator.startCloud(consent: first))
            try await eventually { await f.provider.indices.count == 1 }
            #expect(await f.coordinator.startCloud(consent: second))
            #expect(f.coordinator.jobs[other]?.status == .queued)
            f.settings.isEnabled = false
            try await eventually { f.coordinator.jobs[f.id]?.status == .paused }
            #expect(f.coordinator.jobs[other]?.status == .paused)
            #expect(await f.provider.indices == [0])
            f.settings.isEnabled = true
            #expect(await f.coordinator.startCloud(consent: second) == false)
        }

        @Test func `a checkpoint write failure stops before the next paid section`() async throws {
            let f = try CloudFixture(); defer { f.cleanup() }
            // A file where the checkpoint directory belongs simulates a write failure.
            try Data("unwritable checkpoint destination".utf8).write(to: f.directory.appendingPathComponent("checkpoints"))
            await f.enable()
            try await f.register()
            let consent = try #require(f.coordinator.prepareCloudConsent(lectureID: f.id))
            #expect(await f.coordinator.startCloud(consent: consent))
            try await eventually {
                if case .failed = f.coordinator.jobs[f.id]?.status {
                    return true
                }; return false
            }
            #expect(await f.provider.indices == [0])
            #expect(f.coordinator.jobs[f.id]?.segments.isEmpty == true)
            #expect(f.coordinator.jobs[f.id]?.status == .failed(OpenRouterError.storage.localizedDescription))
        }

        @Test func `removing the key cancels a cloud job and prevents a new upload`() async throws {
            let f = try CloudFixture(); defer { f.cleanup() }
            await f.enable()
            await f.provider.configure(delayed: true)
            try await f.register()
            let consent = try #require(f.coordinator.prepareCloudConsent(lectureID: f.id))
            #expect(await f.coordinator.startCloud(consent: consent))
            try await eventually { await f.provider.indices.count == 1 }
            await f.settings.removeKey()
            try await eventually { f.coordinator.jobs[f.id]?.status == .paused }
            #expect(!f.settings.hasKey)
            let next = try #require(f.coordinator.prepareCloudConsent(lectureID: f.id))
            #expect(await f.coordinator.startCloud(consent: next) == false)
            #expect(await f.provider.indices == [0])
        }
    }
#endif
