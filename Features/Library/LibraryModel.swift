import AppKit
import Observation
import os
import UniformTypeIdentifiers

struct Lecture: Identifiable {
    let id = UUID()
    let title: String
    let url: URL?
    let duration: TimeInterval
    var segments: [TranscriptSegment]
    var sha256: String?

    var isSample: Bool {
        url == nil
    }

    /// Segments are committed through validated checkpoints, so this only fails
    /// for the empty case, which is itself valid.
    var timeline: TranscriptTimeline {
        (try? TranscriptTimeline(segments: segments)) ?? (try! TranscriptTimeline(segments: []))
    }
}

@MainActor @Observable
final class LibraryModel {
    private(set) var lectures: [Lecture] = []
    var selection: UUID? {
        didSet { loadSelection() }
    }

    private(set) var isImporting = false
    var errorMessage: String?
    let playback = PlaybackController()
    let models = ModelManager()
    let worker = WorkerClient()
    let coordinator: TranscriptionCoordinator
    @ObservationIgnored private let importer = AudioImporter()

    var selectedLecture: Lecture? {
        lectures.first { $0.id == selection }
    }

    init() {
        coordinator = TranscriptionCoordinator(worker: worker, models: models)
        coordinator.onSegmentsChanged = { [weak self] lectureID, segments, sha256 in
            self?.apply(segments: segments, sha256: sha256, to: lectureID)
        }
        models.onInstalled = { [weak self] _ in
            self?.coordinator.modelBecameAvailable()
        }
    }

    func chooseAudio() {
        guard !isImporting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3, .mpeg4Audio, .wav, .aiff, .audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in await self?.importAudio(urls) }
        }
    }

    /// Development and automation entry points:
    /// `Wordy --open /path/to/lecture.mp3 [--play] [--install-model whisper-base]`.
    func importLaunchArguments(_ arguments: [String] = CommandLine.arguments) {
        var urls: [URL] = []
        var autoplay = false
        var iterator = arguments.makeIterator()
        Logger(subsystem: "com.wordy.app", category: "library")
            .notice("Launch arguments: \(arguments.count - 1, privacy: .public) (paths redacted)")
        while let argument = iterator.next() {
            switch argument {
            case "--open":
                if let path = iterator.next() { urls.append(URL(fileURLWithPath: path)) }
            case "--play":
                autoplay = true
            case "--install-model":
                if let id = iterator.next(), let model = SpeechModelCatalog.model(id: id) { models.install(model) }
            default:
                continue
            }
        }
        guard !urls.isEmpty else { return }
        Task {
            await importAudio(urls)
            if autoplay, playback.hasAudio, !playback.isPlaying { playback.togglePlayback() }
        }
    }

    func importAudio(_ urls: [URL]) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        var failed = 0
        for url in urls {
            if let existing = lectures.first(where: { $0.url == url }) {
                selection = existing.id; continue
            }
            do {
                let audio = try await importer.inspect(url)
                let lecture = Lecture(title: audio.title, url: audio.url, duration: audio.duration, segments: [])
                lectures.append(lecture)
                selection = lecture.id
                coordinator.register(lectureID: lecture.id, audioURL: audio.url, duration: audio.duration)
            } catch { failed += 1 }
        }
        if failed > 0 {
            errorMessage = "Could not import \(failed) file(s). Choose an accessible file containing playable audio."
        }
    }

    func showSample() {
        if let sample = lectures.first(where: \.isSample) {
            selection = sample.id; return
        }
        let segments = [
            TranscriptSegment(start: 0, end: 12, text: "Welcome to Wordy. This sample shows how a lecture transcript will appear alongside your audio."),
            TranscriptSegment(start: 12, end: 24, text: "Search for a phrase to find the passage you need. Completed transcripts will let you jump directly to that moment in the recording."),
            TranscriptSegment(start: 26, end: 38, text: "Local transcription keeps lecture audio on your Mac. Cloud acceleration will always require an explicit choice."),
            TranscriptSegment(start: 38, end: 52, text: "Long lectures are processed in smaller sections. The player and transcript stay responsive as later sections are prepared."),
            TranscriptSegment(start: 52, end: 65, text: "This is sample text, with no audio attached. Import a recording to try the audio player and local transcription."),
        ]
        let sample = Lecture(title: "Welcome to Wordy", url: nil, duration: 65, segments: segments)
        lectures.append(sample)
        selection = sample.id
    }

    private func apply(segments: [TranscriptSegment], sha256: String?, to lectureID: UUID) {
        guard let index = lectures.firstIndex(where: { $0.id == lectureID }) else { return }
        lectures[index].segments = segments
        lectures[index].sha256 = sha256
        if selection == lectureID {
            playback.updateTimeline(lectures[index].timeline)
        }
    }

    private func loadSelection() {
        guard let lecture = selectedLecture else {
            playback.load(url: nil, duration: 0, timeline: try! TranscriptTimeline(segments: []))
            return
        }
        playback.load(url: lecture.url, duration: lecture.duration, timeline: lecture.timeline)
    }
}
