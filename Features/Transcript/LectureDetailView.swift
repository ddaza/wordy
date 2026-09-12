import SwiftUI

struct LectureDetailView: View {
    let lecture: Lecture
    let playback: PlaybackController
    @State private var query = ""
    @State private var hits: [TranscriptSearchHit] = []
    @State private var followPlayback = true
    @State private var scrollTarget: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(lecture.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(lecture.isSample ? "Sample transcript · no audio attached" : "Local audio · \(playbackTime(lecture.duration))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Follow playback", isOn: $followPlayback)
                    .toggleStyle(.button)
                    .disabled(!playback.hasAudio || lecture.timeline.segments.isEmpty)
            }
            .padding(24)
            Divider()
            if lecture.timeline.segments.isEmpty {
                ContentUnavailableView {
                    Label("Ready to listen", systemImage: "headphones")
                } description: {
                    Text("Your audio is ready. Transcription will be available once the local speech engine is connected.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search this transcript", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Text("\(hits.count) passages").font(.caption).foregroundStyle(.secondary)
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(16)
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if hits.isEmpty {
                        Text("No matching passages").foregroundStyle(.secondary).padding()
                    } else {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(hits) { hit in
                                    Button {
                                        followPlayback = false
                                        scrollTarget = hit.id
                                        if playback.hasAudio { playback.seek(to: hit.time) }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(playbackTime(hit.time)).monospacedDigit()
                                            Text(hit.text).lineLimit(1).frame(width: 200, alignment: .leading)
                                        }.padding(5)
                                    }
                                }
                            }
                        }.padding(.horizontal, 16).padding(.bottom, 12)
                    }
                }
                TranscriptCollectionView(
                    segments: lecture.timeline.segments,
                    activeID: playback.activeSegmentID,
                    highlightedIDs: Set(hits.map(\.id)),
                    scrollTarget: scrollTarget,
                    followPlayback: followPlayback,
                    onManualScroll: { followPlayback = false },
                    onSelect: { playback.seek(to: $0.start) }
                )
            }
            Divider()
            PlayerView(playback: playback, segments: lecture.timeline.segments)
        }
        .task(id: query) {
            let currentQuery = query
            let segments = lecture.timeline.segments
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            let result = await Task.detached(priority: .userInitiated) {
                TranscriptSearch.hits(in: segments, query: currentQuery)
            }.value
            guard !Task.isCancelled else { return }
            hits = result
        }
    }
}
