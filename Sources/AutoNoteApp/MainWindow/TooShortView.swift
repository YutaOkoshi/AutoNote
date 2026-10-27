import AutoNoteCore
import SwiftUI

/// A recording under a minute (§5.9): transcribe it anyway or discard it.
struct TooShortView: View {
    let model: AppModel
    let row: MeetingRow

    var body: some View {
        let id = MeetingID(rawValue: row.id)
        VStack(spacing: 16) {
            Image(systemName: "timer").font(.largeTitle).foregroundStyle(.secondary)
            Text("1 分未満の短すぎる録音です").font(.title3)
            HStack {
                Button("文字起こしする") { run(.notice(.transcribeTooShort(id))) }
                    .buttonStyle(.borderedProminent)
                Button("破棄", role: .destructive) { run(.notice(.discardTooShort(id))) }
            }
        }
        .padding(24)
    }

    private func run(_ action: UserAction) {
        Task {
            await model.perform(action)
            await model.refresh()
        }
    }
}
