import AutoNoteCore
import SwiftUI

/// While recording: stop, pause / resume, bookmark, the language, then the transcript (left) and the live summary
/// (right). With summaries on, the summary pane shows from the start; too narrow for two columns, it sits above
/// the transcript. With summaries off, only the questions show, small, above the transcript.
struct RecordingDetailView: View {
    let model: AppModel
    @State private var width: Double = 0

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
            columns
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { width = $0 }
        }
        .task(id: r.meetingID) {
            if let id = r.meetingID { await model.loadQuestions(.meeting(id)) }
        }
    }

    @ViewBuilder private var columns: some View {
        let id = model.recorder.meetingID
        let update = id.flatMap(model.liveSummary(for:))
        let questions = id.map { model.questions(.meeting($0)) } ?? []
        switch LiveSummaryPresentation.recordingMode(liveSummaryEnabled: model.liveSummaryEnabled,
                                                     hasResult: update?.state != nil) {
        case .sidePane:
            let content = LiveSummaryPresentation.pane(
                state: update?.state, status: update?.status ?? .active, updated: model.liveSummaryUpdatedText,
                questions: questions,
                translation: TranslationPresentation.summaryTranslation(model.liveSummaryTranslation,
                                                                        shown: model.translationShown))
            switch LiveSummaryLayout.arrangement(width: width) {
            case .sideBySide(let paneWidth):
                HStack(spacing: 0) {
                    transcriptPane
                    Divider()
                    LiveSummaryPane(content: content, onEdit: edit(id))
                        .frame(width: paneWidth)
                }
            case .stacked:
                VStack(spacing: 0) {
                    LiveSummaryPane(content: content, onEdit: edit(id))
                        .frame(maxHeight: LiveSummaryLayout.stackedMaxHeight)
                    Divider()
                    transcriptPane
                }
            }
        case .questionsOnly:
            VStack(spacing: 0) {
                if let id {
                    CappedScrollView(maxHeight: LiveSummaryLayout.stackedMaxHeight) {
                        QuestionsPanel(title: LiveSummarySection.questions.title,
                                       content: LiveSummaryPresentation.questionsOnly(questions)) { e in
                            Task { await model.perform(.editQuestion(e, in: .meeting(id))) }
                        }
                        .padding(12)
                    }
                    Divider()
                }
                transcriptPane
            }
        }
    }

    /// 「💬 文字起こし」 with the recognition state at the right end, over the transcript.
    private var transcriptPane: some View {
        VStack(spacing: 0) {
            PaneHeader(symbol: "bubble.left.and.text.bubble.right", title: LiveSummaryPresentation.transcriptTitle) {
                if !model.liveTranslations.isEmpty
                    || TranslationPresentation.hasSummaryTranslation(model.liveSummaryTranslation) {
                    TranslationToggle(model: model)
                }
                if let status = LiveSummaryPresentation.transcriptStatus(model.recorder.state) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(model.recorder.state == .recording ? Color.accentColor : Color.secondary)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            if model.live.lines.isEmpty {
                Text("聞き取り中…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LiveTranscriptView(lines: model.live.lines,
                                   translations: TranslationPresentation.liveTranslations(
                                       model.live.lines, model.liveTranslations, shown: model.translationShown))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The questions' actions, once the recording has its meeting (none while 開始中…).
    private func edit(_ id: MeetingID?) -> ((LiveQuestionEdit) -> Void)? {
        guard let id else { return nil }
        return { e in Task { await model.perform(.editQuestion(e, in: .meeting(id))) } }
    }

    private func run(_ action: UserAction) {
        Task { await model.perform(action) }
    }
}
