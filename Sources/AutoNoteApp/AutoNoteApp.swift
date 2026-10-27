import AutoNoteCore
import SwiftUI

@main
struct AutoNoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(shell: appDelegate.shell)
        } label: {
            MenuBarLabel(shell: appDelegate.shell)
        }

        // Plan 06 Task 14. Opened through `AppShell.open`, which activates the app first (ruling X37).
        Window("AutoNote", id: AppShell.mainWindowID) {
            MainWindow(shell: appDelegate.shell)
        }
        .defaultLaunchBehavior(.suppressed)

        // Plan 06 Task 15. Opened by 設定… (activate first, then `openSettings`) and by the main window's band.
        SwiftUI.Settings {
            SettingsView(shell: appDelegate.shell)
        }
    }
}
