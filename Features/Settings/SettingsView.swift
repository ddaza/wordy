import SwiftUI

struct SettingsView: View {
    let library: LibraryModel
    @State private var status = "Checking local engine…"

    var body: some View {
        Form {
            Section("Transcription") {
                LabeledContent("Default", value: "On this Mac")
                LabeledContent("Local engine") { Text(status).foregroundStyle(.secondary) }
                LabeledContent("Section policy", value: library.coordinator.policy.label)
                Text("Recordings are transcribed locally in sections. Completed sections are saved so an interrupted lecture resumes where it stopped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speech models") {
                LabeledContent("In use") {
                    Text(library.models.selectedModel?.displayName ?? "None")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.models.catalog) { model in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(model.displayName)
                                if model.id == library.models.recommended.id {
                                    Text("Recommended").font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.tint.opacity(0.15), in: Capsule())
                                }
                                if model.id == library.models.selectedID, library.models.installedURL(for: model) != nil {
                                    Text("In use").font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.green.opacity(0.18), in: Capsule())
                                }
                            }
                            Text("\(model.sizeDescription) · \(model.summary)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        modelActions(model)
                    }
                    .padding(.vertical, 2)
                }
                Text("Download any of these models. Wordy uses only the one marked In use, including when you transcribe a lecture again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Connections") {
                LabeledContent("Google Drive", value: "Not available in this build")
                Text("Transcription always runs on this Mac. Recordings and transcripts are never uploaded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
        .task { status = await library.worker.readiness() }
    }

    @ViewBuilder
    private func modelActions(_ model: SpeechModel) -> some View {
        let models = library.models
        if models.state(of: model) == .installed {
            HStack(spacing: 8) {
                if model.id != models.selectedID {
                    Button("Use") { models.select(model) }
                }
                Button("Remove") { models.remove(model) }
            }
        } else {
            ModelInstallButton(model: model, models: models)
        }
    }
}
