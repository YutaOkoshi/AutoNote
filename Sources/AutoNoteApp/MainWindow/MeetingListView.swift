import AppKit
import AutoNoteCore
import SwiftUI

/// The left column: `model.meetings` with the same state words as the menu and the CLI. ⌘/⇧-click selects several
/// meetings. The context menu (`MeetingContextMenu`) offers 「1 つの会議に統合」 (`onMerge`) for two or more, and
/// for one meeting the reruns of its failed automations, 再生成, 「Finder で表示」 and 削除 as the detail view does.
struct MeetingListView: View {
    let env: AppEnvironment
    let model: AppModel
    @Binding var selection: Set<String>
    /// The open editor's unsaved-edits question; 再生成 of the meeting shown in the detail asks it first (I5).
    let unsaved: UnsavedEditsGuard
    let onMerge: ([MeetingID]) -> Void
    /// The meeting 削除 was chosen for, while its confirmation is shown.
    @State private var deleteTarget: MeetingID?

    var body: some View {
        List(selection: $selection) {
            ForEach(model.meetings) { row in
                MeetingListRow(row: row, failures: failures(of: row.id))
                    .tag(row.id)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            ForEach(MeetingContextMenu.actions(selected: ids, rows: model.meetings, automationFailures: model.automationFailures),
                    id: \.self) { action in
                Button(action.title, systemImage: action.systemImage, role: action.isDestructive ? .destructive : nil) {
                    run(action, on: ids)
                }
                .accessibilityLabel(action.title)
            }
        }
        .confirmDeleteMeeting(target: $deleteTarget, model: model)
        .overlay {
            if model.meetings.isEmpty {
                ContentUnavailableView("会議はまだありません", systemImage: "waveform")
            }
        }
    }
}

extension MeetingListView {
    private func failures(of id: String) -> [String] {
        model.automationFailures.filter { $0.meetingID == id }.map(\.name)
    }

    private func run(_ action: MeetingContextAction, on ids: Set<String>) {
        // Every action but 統合 is offered for exactly one meeting.
        let id = MeetingID(rawValue: ids.first ?? "")
        switch action {
        case .merge:
            onMerge(ids.sorted().map { MeetingID(rawValue: $0) })
        case .rerunAutomation(let name):
            // §14.5: a failed automation can be run again from the window too.
            Task { await model.perform(.rerunAutomation(name: name, meetingID: id)) }
        case .regenerate:
            Task { @MainActor in
                // Only the meeting shown in the detail can hold unsaved edits.
                if model.selectedMeetingID == id { guard await unsaved.mayLeave() else { return } }
                await model.perform(.regenerate(id))
            }
        case .revealInFinder:
            let row = model.meetings.first { $0.id == id.rawValue }
            let url = MeetingContextMenu.revealURL(for: row, tracksDirectory: env.paths.tracksDirectory(id))
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .delete:
            deleteTarget = id
        }
    }
}

private struct MeetingListRow: View {
    let row: MeetingRow
    let failures: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.startedAt, format: Self.dateFormat)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let duration = DurationText.list(seconds: row.durationSeconds, minutes: row.durationMinutes) {
                    Text(duration).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if row.silenceWarning {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                        .help("無音の可能性があります")
                }
            }
            .font(.caption)
            Text(row.title)
                .font(.body)
                .lineLimit(1)
            Text(row.state.displayText(progressLabel: row.progressLabel))
                .font(.caption)
                .foregroundStyle(row.state == .failed ? Color.red : Color.secondary)
            ForEach(failures, id: \.self) { name in
                Label("Automation 失敗: \(name)", systemImage: "exclamationmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private static let dateFormat = Date.FormatStyle()
        .year(.defaultDigits).month(.twoDigits).day(.twoDigits)
        .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
}
