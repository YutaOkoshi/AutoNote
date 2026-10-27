import AutoNoteCore
import SwiftUI

/// The left column: `model.meetings` with the same state words as the menu and the CLI (Task 10).
struct MeetingListView: View {
    let model: AppModel
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(model.meetings) { row in
                let failures = model.automationFailures.filter { $0.meetingID == row.id }.map(\.name)
                MeetingListRow(row: row, failures: failures)
                    .tag(row.id)
                    // §14.5: a failed automation can be run again from the window too.
                    .contextMenu {
                        ForEach(failures, id: \.self) { name in
                            Button("再実行: \(name)", systemImage: "arrow.clockwise") {
                                Task { await model.perform(.rerunAutomation(name: name, meetingID: MeetingID(rawValue: row.id))) }
                            }
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
