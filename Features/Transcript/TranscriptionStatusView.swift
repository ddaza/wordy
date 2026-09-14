import SwiftUI

/// Explains what the local engine is doing with the open recording and offers
/// the one action that applies: install the model, pause, resume, or retry.
struct TranscriptionStatusView: View {
    let lecture: Lecture
    let coordinator: TranscriptionCoordinator
    let models: ModelManager
    let isDismissed: Bool
    let onDismiss: () -> Void

    private var job: TranscriptionCoordinator.Job? {
        coordinator.jobs[lecture.id]
    }

    private var modelNeeded: SpeechModel {
        models.selectedModel ?? models.recommended
    }

    var body: some View {
        if let job, shouldShow(job) {
            HStack(spacing: 12) {
                icon(for: job.status)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(for: job)).font(.callout.weight(.medium))
                    Text(detail(for: job)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                actions(for: job)
                if case .complete = job.status {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.quaternary.opacity(0.4))
            .accessibilityElement(children: .contain)
        }
    }

    private func shouldShow(_ job: TranscriptionCoordinator.Job) -> Bool {
        if case .complete = job.status {
            return !isDismissed
        }
        return true
    }

    @ViewBuilder
    private func icon(for status: TranscriptionCoordinator.Status) -> some View {
        switch status {
        case .identifying, .queued, .running:
            ProgressView().controlSize(.small)
        case .waitingForModel:
            Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
        case .paused:
            Image(systemName: "pause.circle").foregroundStyle(.secondary)
        case .complete:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func title(for job: TranscriptionCoordinator.Job) -> String {
        switch job.status {
        case .identifying: "Preparing recording…"
        case .waitingForModel: "Speech model needed"
        case .queued: "Waiting for another lecture to finish"
        case let .running(chunkIndex, chunkCount):
            "Transcribing on this Mac · \(Int(job.fractionComplete * 100))% · section \(chunkIndex + 1) of \(chunkCount)"
        case .paused: "Transcription paused"
        case .complete: job.restoredFromCheckpoint ? "Transcript restored" : "Transcript complete"
        case .failed: "Transcription stopped"
        }
    }

    private func detail(for job: TranscriptionCoordinator.Job) -> String {
        switch job.status {
        case .identifying:
            return "Reading the file to identify it. Nothing leaves your Mac."
        case .waitingForModel:
            return "Download \(modelNeeded.displayName) (\(modelNeeded.sizeDescription)) once; transcription then runs locally."
        case .queued:
            return "Transcription runs one lecture at a time so playback stays smooth."
        case .running:
            var text = "Completed through \(playbackTime(job.completedThrough)) of \(playbackTime(job.duration)). Later passages are still pending."
            if let rtf = job.lastRealTimeFactor, rtf > 0 {
                text += String(format: " Speed %.1f× real time.", 1 / rtf)
            }
            return text
        case .paused:
            return "Completed work through \(playbackTime(job.completedThrough)) is saved."
        case .complete:
            return "All \(job.segments.count) passages are searchable."
        case let .failed(message):
            return message
        }
    }

    @ViewBuilder
    private func actions(for job: TranscriptionCoordinator.Job) -> some View {
        switch job.status {
        case .waitingForModel:
            ModelInstallButton(model: modelNeeded, models: models)
        case .running, .queued:
            Button("Pause") { coordinator.pause(lectureID: lecture.id) }
        case .paused:
            Button("Resume") { coordinator.resume(lectureID: lecture.id) }
        case .failed:
            Button("Retry") { coordinator.resume(lectureID: lecture.id) }
        case .identifying, .complete:
            EmptyView()
        }
    }
}

struct ModelInstallButton: View {
    let model: SpeechModel
    let models: ModelManager

    var body: some View {
        switch models.state(of: model) {
        case .notInstalled:
            Button("Download Model") { models.install(model) }
                .buttonStyle(.borderedProminent)
        case let .downloading(fraction, _):
            HStack(spacing: 8) {
                ProgressView(value: fraction).frame(width: 110)
                Text("\(Int(fraction * 100))%").font(.caption).monospacedDigit()
                Button { models.cancelInstall(model) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel("Cancel download")
            }
        case .verifying:
            Label("Verifying…", systemImage: "checkmark.shield").font(.caption)
        case .installed:
            Label("Installed", systemImage: "checkmark.circle").font(.caption)
        case let .failed(message):
            HStack(spacing: 8) {
                Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2).frame(maxWidth: 260)
                Button("Try Again") { models.install(model) }
            }
        }
    }
}
