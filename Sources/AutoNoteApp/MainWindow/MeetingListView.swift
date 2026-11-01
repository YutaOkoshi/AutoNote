import AutoNoteCore
import SwiftUI

/// The left column: `model.meetings` with the same state words as the menu and the CLI. ⌘/⇧-click selects several
/// meetings; the context menu of two or more offers 「1 つの会議に統合」 (`onMerge`).
struct MeetingListView: View {
    let model: AppModel
    @Binding var selection: Set<String>
    let onMerge: ([MeetingID]) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(model.meetings) { row in
                MeetingListRow(row: row, failures: failures(of: row.id))
                    .tag(row.id)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count >= 2 {
                Button("1 つの会議に統合", systemImage: "rectangle.stack.badge.plus") {
                    onMerge(ids.sorted().map { MeetingID(rawValue: $0) })
                }
            } else if let id = ids.first {
                // §14.5: a failed automation can be run again from the window too.
                ForEach(failures(of: id), id: \.self) { name in
                    Button("再実行: \(name)", systemImage: "arrow.clockwise") {
                        Task { await model.perform(.rerunAutomation(name: name, meetingID: MeetingID(rawValue: id))) }
                    }
                }
            }
        }
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
