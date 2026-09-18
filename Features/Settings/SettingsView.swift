import SwiftUI

struct SettingsView: View {
    let library: LibraryModel
    @State private var apiKey = ""
    @State private var status = "Checking local engine…"

    private var cloud: CloudSettings {
        library.coordinator.cloud
    }

    var body: some View {
        Form {
            Section("Transcription") {
                LabeledContent("In use") {
                    Text(library.coordinator.selectedModelDescription).fontWeight(.semibold)
                }
                Text("New transcriptions and Transcribe Again use this model. A running job keeps its current model. Cloud uploads always require confirmation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: Binding(get: { cloud.isEnabled }, set: { cloud.isEnabled = $0 })) {
                    Label("Advanced Mode", systemImage: "cloud").font(.headline)
                }
                .toggleStyle(.switch)
                Text("Use your own OpenRouter account for cloud transcription. Audio leaves your Mac only after you confirm a recording.")
                    .font(.caption).foregroundStyle(.secondary)
                if cloud.isEnabled {
                    SecureField(cloud.hasKey ? "Replace OpenRouter API key" : "OpenRouter API key", text: $apiKey)
                    HStack {
                        Button(cloud.isSaving ? "Saving…" : "Save Key") {
                            let value = apiKey
                            Task {
                                await cloud.saveKey(value)
                                if cloud.keySaveSucceeded {
                                    apiKey = ""
                                }
                            }
                        }
                        .disabled(apiKey.isEmpty || cloud.isSaving)
                        if cloud.hasKey {
                            Button("Remove Key") { Task { await cloud.removeKey() } }
                                .disabled(cloud.isSaving)
                        }
                        Spacer()
                        Link("Get an API key", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                    }
                    if cloud.hasKey {
                        Label("API key saved in Keychain", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.callout.weight(.medium))
                    }
                    if let message = cloud.message, !cloud.keySaveSucceeded {
                        Text(message).font(.callout).foregroundStyle(.orange)
                    }
                    if !cloud.hasKey {
                        Text("Save your API key to enable the cloud model Use buttons.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(OpenRouterModel.allCases) { model in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(model.displayName)
                                    if cloud.usesCloud, cloud.model == model {
                                        inUseBadge
                                    }
                                }
                                Text(model.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(cloud.usesCloud && cloud.model == model ? "In use" : "Use") {
                                cloud.select(model)
                            }
                            .disabled(!cloud.canSelectModel || (cloud.usesCloud && cloud.model == model))
                            .accessibilityLabel("Use \(model.displayName) with OpenRouter")
                        }
                        .padding(.vertical, 3)
                    }
                    Text("Usage is billed to your OpenRouter account. Choosing Use does not upload audio. Disabling Advanced Mode pauses cloud jobs and returns the selection to local transcription.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Local speech models") {
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
                                if !cloud.usesCloud, model.id == library.models.readyModel?.id {
                                    inUseBadge
                                }
                            }
                            Text("\(model.sizeDescription) · \(model.summary)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        modelActions(model)
                    }
                    .padding(.vertical, 2)
                }
                Text("Choose Use to select a downloaded model for transcription on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Local engine") { Text(status).foregroundStyle(.secondary) }
            }
            Section("Connections") {
                LabeledContent("Google Drive", value: "Not available in this build")
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 700)
        .task {
            await cloud.refresh()
            status = await library.worker.readiness()
        }
    }

    private var inUseBadge: some View {
        Text("In use").font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.green.opacity(0.18), in: Capsule())
    }

    @ViewBuilder
    private func modelActions(_ model: SpeechModel) -> some View {
        let models = library.models
        if models.state(of: model) == .installed {
            HStack(spacing: 8) {
                if cloud.usesCloud || model.id != models.selectedID {
                    Button("Use") { library.coordinator.useLocalModel(model) }
                }
                Button("Remove") { models.remove(model) }
            }
        } else {
            ModelInstallButton(model: model, models: models)
        }
    }
}
