import SwiftUI

@main
struct WordyApp: App {
    @State private var library = LibraryModel()

    var body: some Scene {
        WindowGroup {
            LibraryView(library: library)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1150, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Audio…") { library.chooseAudio() }
                    .keyboardShortcut("o")
            }
        }
        Settings {
            SettingsView()
        }
    }
}
