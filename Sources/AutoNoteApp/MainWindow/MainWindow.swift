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
        // The open flag hangs off a stable container, not the branch, so switching from 起動中… to the content
        // never leaves it false while the window is on screen.
        ZStack {
            if let env = shell.env {
                MainWindowContent(env: env, model: env.model, shell: shell)
            } else {
                ProgressView("起動中…")
                    .frame(minWidth: 720, minHeight: 480)
            }
        }
        .background {
            Color.clear
                .onAppear { shell.isMainWindowOpen = true }
                .onDisappear { shell.isMainWindowOpen = false }
        }
    }
}

/// The open minutes editor registers here while it is shown; a list selection change asks it first (I5).
@MainActor
final class UnsavedEditsGuard {
    private var token: UUID?
    private var confirm: (@MainActor () async -> Bool)?
    private var dirty: (@MainActor () -> Bool)?

    /// `confirm` returns true when leaving is fine (nothing unsaved, saved, or discarded) and false to stay;
    /// `isDirty` says whether there is anything unsaved right now.
    func register(_ token: UUID, isDirty: @escaping @MainActor () -> Bool, confirm: @escaping @MainActor () async -> Bool) {
        self.token = token
        self.dirty = isDirty
        self.confirm = confirm
    }

    /// Only the editor that registered last unregisters (the next meeting's editor may appear first).
    func unregister(_ token: UUID) {
        guard self.token == token else { return }
        self.token = nil
        confirm = nil
        dirty = nil
    }

    func mayLeave() async -> Bool { await confirm?() ?? true }

    /// What `AppModel.hasUnsavedEdits` asks before a stop moves the selection.
    var hasUnsavedEdits: Bool { dirty?() ?? false }
}

/// A file the user dropped or picked, waiting for its start time in `ImportSheet`.
struct ImportCandidate: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct MainWindowContent: View {
    let env: AppEnvironment
    let model: AppModel
    let shell: AppShell
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
                StatusHeader(env: env, model: model, shell: shell)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        // A stop selects the stopped meeting unless the open editor holds unsaved edits (GUI #8).
        .onAppear { model.hasUnsavedEdits = { [unsaved] in unsaved.hasUnsavedEdits } }
        .toolbar {
            // The record actions sit left of the import icon. No keyboard shortcut; 停止 asks nothing.
            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(Array(MainToolbar.actions(for: model.recorder.state).enumerated()), id: \.offset) { _, action in
                    recordButton(action)
                }
                Button("音声ファイルを取り込む…", systemImage: "square.and.arrow.down") { pickFile() }
                    .help("音声ファイルを取り込む…")
                    .accessibilityLabel("音声ファイルを取り込む…")
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
                ProcessingDetailView(env: env, model: model, shell: shell, row: row)
            case .tooShort:
                TooShortView(row: row)
            case .transcriptOnly, .failed:
                MinutesMissingView(env: env, model: model, shell: shell, row: row)
            case .minutesGenerated:
                // One view identity per meeting: no editor state carries over to another meeting.
                CompletedDetailView(env: env, model: model, row: row, unsaved: unsaved)
                    .id(row.id)
            }
        } else if [.recording, .paused, .grace].contains(model.recorder.state) {
            // Nothing selected while recording (or the row is not listed yet: 開始中…): the live view.
            RecordingDetailView(model: model)
        } else if model.meetings.isEmpty {
            EmptyStateView(model: model, shell: shell)
        } else {
            ContentUnavailableView("会議を選んでください", systemImage: "list.bullet.rectangle",
                                   description: Text("音声ファイルをここへドラッグすると取り込めます"))
        }
    }

    @ViewBuilder private func recordButton(_ action: UserAction) -> some View {
        switch action {
        case .start:
            Button { run(.start) } label: { Label("録音を開始", systemImage: "record.circle").labelStyle(.titleAndIcon) }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("録音を開始")
        case .stop:
            Button { run(.stop) } label: { Label("停止", systemImage: "stop.fill").labelStyle(.titleAndIcon) }
                .accessibilityLabel("停止")
        case .resume:
            Button { run(.resume) } label: { Label("再開", systemImage: "play.fill").labelStyle(.titleAndIcon) }
                .accessibilityLabel("再開")
        case .cancelCountdown:
            Button { run(.cancelCountdown) } label: { Label("取り消す", systemImage: "xmark.circle").labelStyle(.titleAndIcon) }
                .accessibilityLabel("取り消す")
        default:
            EmptyView()
        }
    }

    private func run(_ action: UserAction) {
        Task { await model.perform(action) }
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
