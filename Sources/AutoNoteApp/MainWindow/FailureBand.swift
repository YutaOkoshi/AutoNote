import AppKit
import AutoNoteCore
import SwiftUI

/// A failed or waiting job, or a failed summary, as one "what — why" band with the buttons that help (plan 07
/// Task 11). Nothing when the row has nothing to explain. Red for a failure, yellow while waiting.
struct FailureBand: View {
    let env: AppEnvironment
    let model: AppModel
    let shell: AppShell
    let row: MeetingRow
    let item: QueueItemDTO?
    @Environment(\.openSettings) private var openSettings
    @State private var confirmDelete = false

    private var id: MeetingID { MeetingID(rawValue: row.id) }

    var body: some View {
        if let source = FailureExplanation.source(row: row, item: item) {
            let e = FailureExplanation.make(source, outputFolderPath: model.readiness.outputFolder.path)
            let waiting = e.tone == .waiting
            Band(systemImage: waiting ? "clock.badge.exclamationmark" : "exclamationmark.triangle.fill",
                 tint: waiting ? .orange : .red) {
                Text("\(e.what) — \(e.why)")
                Spacer()
                ForEach(e.actions, id: \.self) { action in
                    let title = FailureExplanation.actionTitle(action)
                    Button(title) { run(action, e) }
                        .accessibilityLabel(title)
                }
            }
            .confirmDeleteMeeting(id, model: model, isPresented: $confirmDelete)
        }
    }

    private func run(_ action: FailureExplanation.Action, _ e: FailureExplanation) {
        switch action {
        case .installGuide: Task { await model.perform(.installGuide) }
        case .redetectClaudeAndRerun: Task { await model.perform(.redetectClaudeAndRerun(id)) }
        case .rerun: Task { await model.perform(.notice(.retry(id))) }
        case .loginGuide:
            let alert = NSAlert()
            alert.messageText = e.why
            alert.informativeText = FailureExplanation.loginSteps
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .revealAudio: NSWorkspace.shared.activateFileViewerSelecting([env.paths.tracksDirectory(id)])
        case .delete: confirmDelete = true
        case .changeOutputFolder: shell.showSettings(.general, using: openSettings)
        case .openSystemSettings: NSWorkspace.shared.open(PrivacyPane.microphone)
        }
    }
}

/// The one confirmation before a meeting is deleted (the completed view and the failure band), then the delete.
struct DeleteMeetingConfirmation: ViewModifier {
    let id: MeetingID
    let model: AppModel
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.alert("この会議を削除しますか？", isPresented: $isPresented) {
            Button("削除", role: .destructive) { Task { await delete() } }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("音声、アプリ内のデータ、Vault の会議ファイル、_index.md の行をまとめて削除します。元に戻せません。")
        }
    }

    private func delete() async {
        await model.perform(.delete(id))
        if model.lastError == nil, model.selectedMeetingID == id { model.selectedMeetingID = nil }
        await model.refresh()
    }
}

extension View {
    func confirmDeleteMeeting(_ id: MeetingID, model: AppModel, isPresented: Binding<Bool>) -> some View {
        modifier(DeleteMeetingConfirmation(id: id, model: model, isPresented: isPresented))
    }
}
