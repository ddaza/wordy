import AppKit
import Observation
import UniformTypeIdentifiers

struct Lecture: Identifiable {
    let id = UUID()
    let title: String
    let url: URL?
    let duration: TimeInterval
    let timeline: TranscriptTimeline
    var isSample: Bool {
        url == nil
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
    @ObservationIgnored private let importer = AudioImporter()
    var selectedLecture: Lecture? {
        lectures.first { $0.id == selection }
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

    private func importAudio(_ urls: [URL]) async {
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
                let lecture = try Lecture(title: audio.title, url: audio.url, duration: audio.duration,
                                          timeline: TranscriptTimeline(segments: []))
                lectures.append(lecture)
                selection = lecture.id
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
            TranscriptSegment(start: 52, end: 65, text: "This is sample text, with no audio attached. Import a recording to try the audio player. Transcription is not connected in this development build."),
        ]
        let sample = Lecture(title: "Welcome to Wordy", url: nil, duration: 65,
                             timeline: try! TranscriptTimeline(segments: segments))
        lectures.append(sample)
        selection = sample.id
    }

    private func loadSelection() {
        guard let lecture = selectedLecture else {
            playback.load(url: nil, duration: 0, timeline: try! TranscriptTimeline(segments: []))
            return
        }
        playback.load(url: lecture.url, duration: lecture.duration, timeline: lecture.timeline)
    }
}
