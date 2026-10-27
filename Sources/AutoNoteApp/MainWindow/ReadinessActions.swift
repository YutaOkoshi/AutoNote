import AutoNoteCore
import SwiftUI

/// One readiness action as a button (plan 07 Task 10). The readiness card, the readiness bands, the failure views
/// and the menu all use this, so an action does the same thing wherever it is pressed.
struct ReadinessActionButton: View {
    let action: ReadinessRow.Action
    let model: AppModel
    let shell: AppShell
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let title = ReadinessPresentation.actionTitle(action)
        Button(title) { run() }
            .accessibilityLabel(title)
    }

    private func run() {
        switch action {
        case .changeOutputFolder: shell.showSettings(.general, using: openSettings)
        case .retryModelDownload: Task { await model.perform(.retryModelDownload) }
        case .installGuide: Task { await model.perform(.installGuide) }
        case .redetectClaude: Task { await model.perform(.redetectClaude) }
        }
    }
}
