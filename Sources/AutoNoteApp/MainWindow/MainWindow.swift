import AppKit
import AutoNoteCore
import SwiftUI
import UniformTypeIdentifiers

/// The main window (plan 06 Task 14): the meeting list on the left, the selected meeting on the right, the status
/// bands above it. Everything that changes data goes through `AppModel.perform`, except the minutes save, which the
/// brief routes through `MeetingsPort.saveMinutes` directly.
struct MainWindow: View {
    let shell: AppShell

    var body: some View {
        if let env = shell.env {
            MainWindowContent(env: env, model: env.model)
        } else {
            ProgressView("起動中…")
                .frame(minWidth: 720, minHeight: 480)
        }
    }
}

/// The open minutes editor registers here while it is shown; a list selection change asks it first (I5).
@MainActor
final class UnsavedEditsGuard {
    private var token: UUID?
    private var confirm: (@MainActor () async -> Bool)?

    /// `confirm` returns true when leaving is fine (nothing unsaved, saved, or discarded) and false to stay.
    func register(_ token: UUID, confirm: @escaping @MainActor () async -> Bool) {
        self.token = token
        self.confirm = confirm
    }

    /// Only the editor that registered last unregisters (the next meeting's editor may appear first).
    func unregister(_ token: UUID) {
        guard self.token == token else { return }
        self.token = nil
        confirm = nil
    }

    func mayLeave() async -> Bool { await confirm?() ?? true }
}

/// A file the user dropped or picked, waiting for its start time in `ImportSheet`.
struct ImportCandidate: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct MainWindowContent: View {
    let env: AppEnvironment
    let model: AppModel
    @State private var importCandidate: ImportCandidate?
    @State private var unsaved = UnsavedEditsGuard()

    /// The list selection is the model's `selectedMeetingID` itself, so a notice tap that sets it while the window
    /// is already open moves the selection too. A change from the list first asks the open editor about unsaved
    /// minutes (保存 / 破棄 / キャンセル); キャンセル keeps the current selection.
    private var selection: Binding<String?> {
        Binding(get: { model.selectedMeetingID?.rawValue },
                set: { [unsaved, model] new in
                    let target = new.map { MeetingID(rawValue: $0) }
                    guard target != model.selectedMeetingID else { return }
                    Task { @MainActor in
                        if await unsaved.mayLeave() { model.selectedMeetingID = target }
                    }
                })
    }

    private var selectedRow: MeetingRow? {
        guard let id = model.selectedMeetingID?.rawValue else { return nil }
        return model.meetings.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView {
            MeetingListView(model: model, selection: selection)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            VStack(spacing: 0) {
                StatusHeader(env: env, model: model)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("音声ファイルを取り込む…", systemImage: "square.and.arrow.down") { pickFile() }
                    .help("音声ファイルを取り込む…")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: Self.isSupported) else { return false }
            importCandidate = ImportCandidate(url: url)
            return true
        }
        .sheet(item: $importCandidate) { candidate in
            ImportSheet(url: candidate.url) { startedAt in
                importCandidate = nil
                Task { await model.perform(.importAudio(candidate.url, startedAt: startedAt)) }
            } onCancel: {
                importCandidate = nil
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let row = selectedRow {
            switch row.state {
            case .recording:
                RecordingDetailView(model: model)
            case .processing, .recorded:
                ProcessingDetailView(env: env, model: model, row: row)
            case .tooShort:
                TooShortView(model: model, row: row)
            case .transcriptOnly, .failed:
                MinutesMissingView(env: env, model: model, row: row)
            case .minutesGenerated:
                // One view identity per meeting: no editor state carries over to another meeting.
                CompletedDetailView(env: env, model: model, row: row, unsaved: unsaved)
                    .id(row.id)
            }
        } else if [.recording, .paused, .grace].contains(model.recorder.state) {
            // Nothing selected while recording (or the row is not listed yet: 開始中…): the live view.
            RecordingDetailView(model: model)
        } else {
            ContentUnavailableView("会議を選んでください", systemImage: "list.bullet.rectangle",
                                   description: Text("音声ファイルをここへドラッグすると取り込めます"))
        }
    }

    private static func isSupported(_ url: URL) -> Bool {
        AudioImporter.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = AudioImporter.supportedExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "選択"
        guard panel.runModal() == .OK, let url = panel.url, Self.isSupported(url) else { return }
        importCandidate = ImportCandidate(url: url)
    }
}
