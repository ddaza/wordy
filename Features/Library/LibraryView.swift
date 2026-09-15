import AppKit
import SwiftUI

struct LibraryView: View {
    @Bindable var library: LibraryModel

    var body: some View {
        NavigationSplitView {
            List(selection: $library.selection) {
                ForEach(library.lectures) { lecture in
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(lecture.title).lineLimit(2)
                            Text(lecture.isSample ? "Sample transcript" : subtitle(for: lecture))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: lecture.isSample ? "text.quote" : "waveform")
                            .foregroundStyle(.tint)
                    }
                    .padding(.vertical, 5)
                    .tag(lecture.id)
                }
            }
            .navigationTitle("Wordy")
            .navigationSplitViewColumnWidth(min: 210, ideal: 250)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("On your Mac", systemImage: "lock.shield")
                        .font(.callout.weight(.medium))
                    Text("This development build keeps imports for this session only.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Explore sample transcript") { library.showSample() }
                        .buttonStyle(.link)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.bar)
            }
        } detail: {
            if let lecture = library.selectedLecture {
                LectureDetailView(lecture: lecture, library: library)
                    .id(lecture.id)
            } else {
                ContentUnavailableView {
                    Label {
                        Text("Wordy: Audio Transcribe")
                    } icon: {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                } description: {
                    Text("Import an audio file to start listening, or explore a sample transcript.")
                } actions: {
                    Button("Import Audio…") { library.chooseAudio() }
                        .buttonStyle(.borderedProminent)
                    Button("Explore Sample") { library.showSample() }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                if library.isImporting {
                    ProgressView().controlSize(.small)
                }
            }
            ToolbarItem {
                Button { library.chooseAudio() } label: { Label("Import Audio", systemImage: "plus") }
                    .disabled(library.isImporting)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            library.playback.shutdown()
        }
        .alert("Import unavailable", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: {
                if !$0 {
                    library.errorMessage = nil
                }
            },
        )) {
            Button("OK", role: .cancel) { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") }
    }

    private func subtitle(for lecture: Lecture) -> String {
        let duration = playbackTime(lecture.duration)
        guard let job = library.coordinator.jobs[lecture.id] else { return duration }
        switch job.status {
        case .identifying: return "\(duration) · preparing"
        case .waitingForModel: return "\(duration) · model needed"
        case .queued: return "\(duration) · waiting"
        case .running: return "\(duration) · transcribing \(Int(job.fractionComplete * 100))%"
        case .paused: return "\(duration) · paused"
        case .complete: return "\(duration) · transcribed"
        case .failed: return "\(duration) · stopped"
        }
    }
}
