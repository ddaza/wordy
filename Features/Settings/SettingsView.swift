import SwiftUI

struct SettingsView: View {
    @State private var status = "Checking local engine…"
    @State private var worker = WorkerClient()

    var body: some View {
        Form {
            Section("Transcription") {
                LabeledContent("Default", value: "On this Mac")
                LabeledContent("Local engine") { Text(status).foregroundStyle(.secondary) }
                Text("The local speech engine and model download will be added next.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Connections") {
                LabeledContent("Google Drive", value: "Not available in this build")
                LabeledContent("Cloud acceleration", value: "Not available in this build")
                Text("Cloud processing will require your explicit choice before audio is uploaded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 530, height: 330)
        .task { status = await worker.readiness() }
    }
}
