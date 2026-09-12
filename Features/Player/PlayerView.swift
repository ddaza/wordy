import SwiftUI

struct PlayerView: View {
    @Bindable var playback: PlaybackController
    let segments: [TranscriptSegment]
    @State private var scrubTime: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: 14) {
            if let segment = segments.first(where: { $0.id == playback.activeSegmentID }) {
                Text(segment.text).font(.callout).multilineTextAlignment(.center).lineLimit(3)
                    .frame(maxWidth: .infinity).accessibilityLabel("Current caption: \(segment.text)")
            }
            HStack(spacing: 12) {
                Text(playbackTime(isScrubbing ? scrubTime : playback.time)).monospacedDigit()
                    .frame(minWidth: 52, alignment: .trailing)
                Slider(value: Binding(
                    get: { isScrubbing ? scrubTime : min(playback.time, playback.duration) },
                    set: { scrubTime = $0 }
                ), in: 0...max(playback.duration, 1), onEditingChanged: { editing in
                    if editing { scrubTime = playback.time; isScrubbing = true }
                    else { isScrubbing = false; playback.seek(to: scrubTime) }
                })
                .accessibilityLabel("Playback position")
                Text(playbackTime(playback.duration)).monospacedDigit().frame(minWidth: 52, alignment: .leading)
            }
            HStack(spacing: 22) {
                Picker("Speed", selection: $playback.speed) {
                    ForEach([Float(0.75), 1, 1.25, 1.5, 1.75, 2], id: \.self) { speed in
                        Text("\(speed.formatted())×").tag(speed)
                    }
                }.frame(width: 130)
                Spacer()
                Button { playback.seek(to: playback.time - 15) } label: { Image(systemName: "gobackward.15") }
                    .accessibilityLabel("Back 15 seconds")
                Button { playback.togglePlayback() } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38)).foregroundStyle(.tint)
                }.buttonStyle(.plain).accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                Button { playback.seek(to: playback.time + 15) } label: { Image(systemName: "goforward.15") }
                    .accessibilityLabel("Forward 15 seconds")
                Spacer()
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Slider(value: $playback.volume, in: 0...1).frame(width: 90).accessibilityLabel("Volume")
            }
        }
        .padding(20)
        .disabled(!playback.hasAudio)
        .background(.bar)
    }
}
