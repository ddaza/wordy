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
                            }
                            Text("\(model.sizeDescription) · \(model.summary)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if library.models.state(of: model) == .installed {
                            Button("Remove") { library.models.remove(model) }
                        } else {
                            ModelInstallButton(model: model, models: library.models)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Text("Models are downloaded from the whisper.cpp project, verified against a pinned checksum, and stored in Wordy's Application Support folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Connections") {
                LabeledContent("Google Drive", value: "Not available in this build")
                Text("Transcription always runs on this Mac. Recordings and transcripts are never uploaded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
        .task { status = await library.worker.readiness() }
    }
}
