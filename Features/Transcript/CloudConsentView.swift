import SwiftUI

struct CloudConsentView: View {
    let consent: TranscriptionCoordinator.CloudConsent
    let coordinator: TranscriptionCoordinator
    let onClose: () -> Void
    @State private var starting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(consent.restarting ? "Transcribe Again with OpenRouter?" : "Transcribe with OpenRouter?").font(.title2.bold())
            Text(consent.title).font(.headline)
            LabeledContent("Recording length", value: playbackTime(consent.duration))
            LabeledContent("Model for this job", value: "\(consent.model.displayName) · OpenRouter")
            Text(consent.model.rawValue).font(.caption).foregroundStyle(.secondary)
            Text("Audio from this recording will leave your Mac and be sent to OpenRouter and its transcription provider. Usage is billed to your OpenRouter account at their current rates.")
            Link("View current model pricing and providers", destination: URL(string: "https://openrouter.ai/\(consent.model.rawValue)")!)
            Text(consent.restarting
                ? "This starts a new transcript with the model shown above. The current transcript is replaced when the first section is saved. Bookmarks are kept."
                : "Matching completed cloud sections are kept when resuming. A new cloud transcript replaces the current transcript when the first section is saved. Bookmarks are kept.")
            Text("Pausing stops further uploads, but a request already accepted by the provider may still run and be charged. Retrying an unfinished section may charge for it again.")
                .font(.callout).foregroundStyle(.secondary)
            if !coordinator.cloud.hasKey {
                Text("Save your OpenRouter API key in Settings first.").foregroundStyle(.orange)
                SettingsLink { Text("Open Settings") }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction).disabled(starting)
                Button("Upload and Transcribe") {
                    starting = true
                    Task {
                        if await coordinator.startCloud(consent: consent) {
                            onClose()
                        } else {
                            errorMessage = coordinator.cloud.message ?? "Authorization changed. Close this window and confirm the recording again."
                        }
                        starting = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(starting || !coordinator.cloud.isEnabled || !coordinator.cloud.hasKey)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(starting)
    }
}
