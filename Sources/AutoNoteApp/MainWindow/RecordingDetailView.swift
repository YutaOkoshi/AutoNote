import AutoNoteCore
import SwiftUI

/// While recording: stop, pause / resume, bookmark, the language, and the live transcript.
struct RecordingDetailView: View {
    let model: AppModel

    var body: some View {
        let r = model.recorder
        let active = [.recording, .paused, .grace].contains(r.state)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("停止", systemImage: "stop.fill") { run(.stop) }
                if r.state == .paused {
                    Button("再開", systemImage: "play.fill") { run(.resume) }
                } else {
                    Button("一時停止", systemImage: "pause.fill") { run(.pause) }
                        .disabled(r.state != .recording)
                }
                Button("ブックマーク", systemImage: "bookmark") { run(.bookmark(nil)) }
                Spacer()
                Picker("言語", selection: Binding(get: { r.language }, set: { run(.setLanguage($0)) })) {
                    Text("自動").tag(Language.auto)
                    Text("日本語").tag(Language.ja)
                    Text("英語").tag(Language.en)
                }
                .fixedSize()
            }
            .disabled(!active)
            .padding(12)
            Divider()
            LiveTranscriptView(lines: model.live.lines)
        }
    }

    private func run(_ action: UserAction) {
        Task { await model.perform(action) }
    }
}
