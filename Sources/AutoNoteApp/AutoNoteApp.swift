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

        // Task 14: the main window replaces this placeholder.
        Window("AutoNote", id: AppShell.mainWindowID) {
            Text("AutoNote")
                .frame(minWidth: 480, minHeight: 320)
        }
        .defaultLaunchBehavior(.suppressed)

        // Launch item 4 (§11.6).
        Window("AutoNote", id: AppShell.consentWindowID) {
            ConsentNoticeView(shell: appDelegate.shell)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // Task 15: the settings tabs replace this placeholder.
        SwiftUI.Settings {
            Text("設定")
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}
