import CryptoKit
import Foundation
import Observation
import os

/// Installs speech models from the trusted catalog into app-managed storage.
/// Downloads resume from a partial file, are verified against the pinned
/// SHA-256, and are activated with an atomic move so a file at the final path
/// is always a verified model.
@MainActor @Observable
final class ModelManager {
    enum State: Equatable {
        case notInstalled
        case downloading(fraction: Double, receivedBytes: Int64)
        case verifying
        case installed
        case failed(String)
    }

    private(set) var states: [String: State] = [:]
    let catalog = SpeechModelCatalog.models
    let recommended: SpeechModel
    /// The catalog model Wordy will use for every new transcription job.
    private(set) var selectedID: String?
    /// Invoked when the selected model is installed and ready for jobs.
    var onReadyModelChanged: (() -> Void)?
    private let directory: URL
    private let defaults: UserDefaults
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let downloader = ModelDownloader()

    private static let selectedModelKey = "wordy.selectedModelID"

    init(directory: URL = AppDirectories.models, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
        recommended = SpeechModelCatalog.model(id: SpeechModelCatalog.recommendedModelID(isAppleSilicon: HostDescription.isAppleSilicon))!
        selectedID = defaults.string(forKey: Self.selectedModelKey)
        if let selectedID, SpeechModelCatalog.model(id: selectedID) == nil {
            self.selectedID = nil
        }
        refresh()
        if selectedID == nil {
            recoverSelection()
        }
    }

    var selectedModel: SpeechModel? {
        selectedID.flatMap(SpeechModelCatalog.model(id:))
    }

    /// The single model transcription jobs should use. Nil until an installed
    /// catalog model has been picked.
    var readyModel: SpeechModel? {
        guard let selected = selectedModel, installedURL(for: selected) != nil else {
            return nil
        }
        return selected
    }

    func state(of model: SpeechModel) -> State {
        states[model.id] ?? .notInstalled
    }

    func installedURL(for model: SpeechModel) -> URL? {
        let url = directory.appendingPathComponent(model.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func refresh() {
        for model in catalog where tasks[model.id] == nil {
            states[model.id] = installedURL(for: model) != nil ? .installed : .notInstalled
        }
    }

    /// Makes this the model used for every new transcription job.
    func select(_ model: SpeechModel) {
        selectedID = model.id
        defaults.set(model.id, forKey: Self.selectedModelKey)
        if installedURL(for: model) != nil {
            onReadyModelChanged?()
        }
    }

    private func recoverSelection() {
        if installedURL(for: recommended) != nil {
            select(recommended)
        } else if let installed = catalog.first(where: { installedURL(for: $0) != nil }) {
            select(installed)
        }
    }

    func install(_ model: SpeechModel) {
        Logger(subsystem: "com.wordy.app", category: "models").notice("Install requested: \(model.id, privacy: .public)")
        guard tasks[model.id] == nil, installedURL(for: model) == nil else { return }
        guard model.isPinned else {
            states[model.id] = .failed("This model is not yet verified for this build.")
            return
        }
        states[model.id] = .downloading(fraction: 0, receivedBytes: 0)
        tasks[model.id] = Task { await performInstall(model) }
    }

    private func performInstall(_ model: SpeechModel) async {
        defer { tasks[model.id] = nil }
        let destination = directory.appendingPathComponent(model.fileName)
        let partial = directory.appendingPathComponent(model.fileName + ".partial")
        do {
            try AppDirectories.ensureExists(destination.deletingLastPathComponent())
            try await downloader.download(model, to: partial) { received, total in
                Task { @MainActor in self.updateProgress(model.id, received: received, total: total) }
            }
            states[model.id] = .verifying
            let digest = try await downloader.sha256(of: partial)
            guard digest == model.sha256 else {
                try? FileManager.default.removeItem(at: partial)
                throw ModelDownloader.DownloadError.checksumMismatch
            }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
            states[model.id] = .installed
            if selectedID == nil {
                select(model)
            } else if selectedID == model.id {
                onReadyModelChanged?()
            }
        } catch is CancellationError {
            states[model.id] = .notInstalled
        } catch {
            states[model.id] = .failed(error.localizedDescription)
        }
    }

    private func updateProgress(_ modelID: String, received: Int64, total: Int64) {
        guard case .downloading = states[modelID] ?? .notInstalled else { return }
        let fraction = total > 0 ? Double(received) / Double(total) : 0
        states[modelID] = .downloading(fraction: min(1, fraction), receivedBytes: received)
    }

    func cancelInstall(_ model: SpeechModel) {
        tasks[model.id]?.cancel()
    }

    func remove(_ model: SpeechModel) {
        guard tasks[model.id] == nil, let url = installedURL(for: model) else { return }
        try? FileManager.default.removeItem(at: url)
        states[model.id] = .notInstalled
        if selectedID == model.id {
            selectedID = nil
            defaults.removeObject(forKey: Self.selectedModelKey)
        }
    }
}

/// Network and hashing work stays off the main actor.
actor ModelDownloader {
    enum DownloadError: LocalizedError {
        case badResponse(Int)
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case let .badResponse(code): "The model download failed (server response \(code)). Check your connection and try again."
            case .checksumMismatch: "The downloaded model did not match its expected checksum and was discarded."
            }
        }
    }

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    func download(_ model: SpeechModel, to partial: URL,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
    {
        let existing = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        var request = URLRequest(url: model.downloadURL)
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.badResponse(0) }
        var received: Int64
        switch http.statusCode {
        case 206 where existing > 0:
            received = existing
        case 200:
            received = 0
            try? FileManager.default.removeItem(at: partial)
        case 416:
            // The partial file is already complete.
            progress(existing, existing)
            return
        default:
            throw DownloadError.badResponse(http.statusCode)
        }
        let total = received + max(0, http.expectedContentLength)
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var lastReport = ContinuousClock.now
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if ContinuousClock.now - lastReport > .milliseconds(200) {
                    progress(received, total)
                    lastReport = .now
                }
            }
            try Task.checkCancellation()
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        progress(received, total)
    }

    func sha256(of url: URL) throws -> String {
        try AudioContentDigest.sha256(of: url)
    }
}
