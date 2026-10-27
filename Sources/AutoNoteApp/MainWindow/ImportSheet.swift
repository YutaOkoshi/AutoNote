import AutoNoteCore
import SwiftUI

/// Asks for the meeting's start time before importing an audio file (§10). The default is the file's creation date.
struct ImportSheet: View {
    let url: URL
    let onImport: (Date) -> Void
    let onCancel: () -> Void
    @State private var startedAt: Date

    init(url: URL, onImport: @escaping (Date) -> Void, onCancel: @escaping () -> Void) {
        self.url = url
        self.onImport = onImport
        self.onCancel = onCancel
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        _startedAt = State(initialValue: created ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("音声ファイルを取り込む").font(.headline)
            LabeledContent("ファイル") {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            }
            DatePicker("会議の開始日時", selection: $startedAt, displayedComponents: [.date, .hourAndMinute])
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("取り込む") { onImport(startedAt) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
