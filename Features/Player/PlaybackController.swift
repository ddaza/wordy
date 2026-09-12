import AVFoundation
import Observation

@MainActor @Observable
final class PlaybackController {
    private(set) var time: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var hasAudio = false
    private(set) var activeSegmentID: UUID?
    var speed: Float = 1 { didSet { if isPlaying { player.rate = speed } } }
    var volume: Float = 1 { didSet { player.volume = volume } }
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var scopedURL: URL?
    @ObservationIgnored private var timeline = try! TranscriptTimeline(segments: [])

    init() {
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.updateTime(time.seconds) }
        }
    }

    func load(url: URL?, duration: TimeInterval, timeline: TranscriptTimeline) {
        player.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        self.timeline = timeline
        self.duration = duration
        isPlaying = false
        hasAudio = url != nil
        if let url {
            if url.startAccessingSecurityScopedResource() { scopedURL = url }
            let item = AVPlayerItem(url: url)
            item.audioTimePitchAlgorithm = .timeDomain
            player.replaceCurrentItem(with: item)
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.isPlaying = false }
            }
        }
        updateTime(0)
    }

    func togglePlayback() {
        guard hasAudio else { return }
        if isPlaying { player.pause() } else {
            if time >= duration { seek(to: 0) }
            player.playImmediately(atRate: speed)
        }
        isPlaying.toggle()
    }

    func seek(to value: TimeInterval) {
        guard hasAudio, value.isFinite else { return }
        let value = min(max(value, 0), duration)
        player.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        // Caption position is updated from the media clock, not the requested target.
    }

    private func updateTime(_ value: TimeInterval) {
        guard value.isFinite else { return }
        time = max(0, value)
        let id = hasAudio ? timeline.activeSegment(at: time)?.id : nil
        if activeSegmentID != id { activeSegmentID = id }
    }

    func shutdown() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }
}

func playbackTime(_ seconds: TimeInterval) -> String {
    let value = seconds.isFinite ? Int(max(0, seconds)) : 0
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
    return String(format: "%d:%02d", value / 60, value % 60)
}
