import AutoNoteCore
import SwiftUI

@main
struct AutoNoteApp: App {
    var body: some Scene {
        MenuBarExtra("AutoNote", systemImage: "waveform") {
            Text("バージョン: \(AutoNoteVersion.current)")
            Divider()
            Button("終了") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
