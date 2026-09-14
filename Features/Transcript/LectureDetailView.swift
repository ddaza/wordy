import SwiftUI

struct LectureDetailView: View {
    let lecture: Lecture
    let library: LibraryModel
    @State private var query = ""
    @State private var hits: [TranscriptSearchHit] = []
    @State private var followPlayback = true
    @State private var scrollTarget: UUID?

    private var playback: PlaybackController {
        library.playback
    }

    private var job: TranscriptionCoordinator.Job? {
        library.coordinator.jobs[lecture.id]
    }

    private var isPartial: Bool {
        guard let job else { return false }
        return job.status != .complete
    }

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
                    .disabled(!playback.hasAudio || lecture.segments.isEmpty)
            }
            .padding(24)
            if !lecture.isSample {
                TranscriptionStatusView(lecture: lecture, coordinator: library.coordinator, models: library.models)
            }
            Divider()
            if lecture.segments.isEmpty {
                ContentUnavailableView {
                    Label(job?.status.isActive == true ? "Listening to the first section" : "Ready to listen",
                          systemImage: "headphones")
                } description: {
                    Text(job?.status.isActive == true
                        ? "The first passages appear as soon as the first section is transcribed. You can start playback now."
                        : "Your audio is ready. Transcribed passages will appear here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(isPartial ? "Search completed passages" : "Search this transcript", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Text("\(hits.count) passages").font(.caption).foregroundStyle(.secondary)
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(16)
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if isPartial {
                        Text("Only passages transcribed so far are searched.")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
                    }
                    if hits.isEmpty {
                        Text("No matching passages").foregroundStyle(.secondary).padding()
                    } else {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(hits) { hit in
                                    Button {
                                        followPlayback = false
                                        scrollTarget = hit.id
                                        if playback.hasAudio {
                                            playback.seek(to: hit.time)
                                        }
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
                    segments: lecture.segments,
                    activeID: playback.activeSegmentID,
                    highlightedIDs: Set(hits.map(\.id)),
                    scrollTarget: scrollTarget,
                    followPlayback: followPlayback,
                    onManualScroll: { followPlayback = false },
                    onSelect: { playback.seek(to: $0.start) },
                )
                if let job, isPartial, job.completedThrough < lecture.duration {
                    Divider()
                    Label("Remaining \(playbackTime(lecture.duration - job.completedThrough)) pending transcription",
                          systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
            Divider()
            PlayerView(playback: playback, segments: lecture.segments)
        }
        .task(id: SearchKey(query: query, segmentCount: lecture.segments.count)) {
            let currentQuery = query
            let segments = lecture.segments
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            let result = await Task.detached(priority: .userInitiated) {
                TranscriptSearch.hits(in: segments, query: currentQuery)
            }.value
            guard !Task.isCancelled else { return }
            hits = result
        }
    }

    private struct SearchKey: Equatable {
        let query: String
        let segmentCount: Int
    }
}
