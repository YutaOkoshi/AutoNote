import AppKit
import AutoNoteCore
import SwiftUI

/// A meeting with minutes: the editor, the bookmarks, the final transcript (read-only, §9.4) and the actions.
struct CompletedDetailView: View {
    let env: AppEnvironment
    let model: AppModel
    let row: MeetingRow
    let unsaved: UnsavedEditsGuard

    @State private var guardToken = UUID()
    @State private var original: MinutesOutput?
    @State private var draft: EditableMinutes?
    @State private var bookmarks: [Bookmark] = []
    @State private var transcript: [LiveLine] = []
    @State private var renameFile = false
    @State private var confirmOverwrite = false
    @State private var confirmDelete = false
    @State private var saving = false
    @State private var message: String?
    @State private var errorText: String?

    private var id: MeetingID { MeetingID(rawValue: row.id) }

    var body: some View {
        VStack(spacing: 0) {
            if let saved = model.justSaved, saved.id == id {
                Band(systemImage: "checkmark.circle.fill", tint: .green) {
                    Text(ProcessingPresentation.savedBand(path: saved.path, home: NSHomeDirectory()))
                    Spacer()
                }
            }
            actions
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    }
                    if draft != nil {
                        // §9.1: the rename box shows once the title changed, off by default.
                        MinutesEditor(minutes: Binding(get: { draft ?? EditableMinutes(Self.empty) }, set: { draft = $0 }),
                                      renameFile: titleChanged ? $renameFile : nil)
                    } else {
                        Text("議事録を読み込めませんでした").foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ブックマーク").font(.headline)
                        if bookmarks.isEmpty { Text("（なし）").foregroundStyle(.secondary) }
                        ForEach(bookmarks.indices, id: \.self) { i in
                            Label {
                                Text("\(bookmarks[i].at.hhmmss)\(bookmarks[i].note.map { "  \($0)" } ?? "")")
                                    .monospacedDigit()
                            } icon: {
                                Image(systemName: "bookmark.fill").foregroundStyle(.orange)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("文字起こし（確定版）").font(.headline)
                        TranscriptList(lines: transcript)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: row.id) { await load() }
        .onAppear { unsaved.register(guardToken) { await confirmLeave() } }
        .onDisappear { unsaved.unregister(guardToken) }
        // 「保存しました」 is about the saved state only.
        .onChange(of: draft) { message = nil }
        .alert("Vault の会議ファイルがアプリの外で編集されています。上書きしますか？", isPresented: $confirmOverwrite) {
            Button("上書きする", role: .destructive) { Task { _ = await save(overwrite: true) } }
            Button("キャンセル", role: .cancel) {}
        }
    }

    /// Unsaved edits: the minutes (title included) differ from what was loaded or last saved.
    private var isDirty: Bool { draft != nil && draft?.minutes != original }

    private var titleChanged: Bool {
        guard let original, let draft else { return false }
        return original.title != draft.title
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("保存", systemImage: "square.and.arrow.down.on.square") { Task { _ = await save(overwrite: false) } }
                .disabled(draft == nil || draft?.minutes == original || saving)
                .keyboardShortcut("s")
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("再生成", systemImage: "arrow.clockwise") {
                Task {
                    guard await confirmLeave() else { return }
                    await model.perform(.regenerate(id))
                }
            }
            Button("Finder で表示", systemImage: "folder") {
                guard let path = row.filePath else { return }
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
            }
            .accessibilityLabel("Finder で表示")
            .disabled(row.filePath == nil)
            if Self.obsidianInstalled {
                Button("Obsidian で開く", systemImage: "arrow.up.forward.app") {
                    guard let path = row.filePath else { return }
                    Task { await WorkspaceOpener().open(URL(filePath: path)) }
                }
                .disabled(row.filePath == nil)
            }
            Button("この会議を削除", systemImage: "trash", role: .destructive) { confirmDelete = true }
                // On its own view: a second `.alert` on the same view as the overwrite one is not shown.
                .alert("この会議を削除しますか？", isPresented: $confirmDelete) {
                    Button("削除", role: .destructive) { Task { await delete() } }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("音声、アプリ内のデータ、Vault の会議ファイル、_index.md の行をまとめて削除します。元に戻せません。")
                }
        }
        .padding(12)
    }

    private func load() async {
        let meetings = env.ports.meetings
        do {
            let minutes = try await meetings.minutes(id)
            original = minutes
            draft = minutes.map(EditableMinutes.init)
            bookmarks = (try? await meetings.manifest(id))?.bookmarks ?? []
            transcript = LiveTranscriptView.lines(try await meetings.transcript(id, kind: .final)?.utterances ?? [])
            renameFile = false
            message = nil
            errorText = nil
        } catch {
            // Nothing from another meeting may stay editable (or be saved under this id).
            original = nil
            draft = nil
            bookmarks = []
            transcript = []
            renameFile = false
            message = nil
            errorText = CommandRouter.ipcError(error).message
        }
    }

    private enum SaveOutcome { case saved, externallyEdited, failed }

    /// The normal save path. `askOverwrite` false: an external edit is reported to the caller instead of
    /// raising the window's overwrite alert.
    private func save(overwrite: Bool, askOverwrite: Bool = true) async -> SaveOutcome {
        guard let edited = draft?.minutes else { return .failed }
        saving = true
        defer { saving = false }
        do {
            switch try await env.ports.meetings.saveMinutes(id, edited, renameFile: titleChanged && renameFile, overwrite: overwrite) {
            case .saved:
                original = edited
                renameFile = false
                message = "保存しました"
                errorText = nil
                await model.refresh()
                return .saved
            case .externallyEdited:
                if askOverwrite { confirmOverwrite = true }
                return .externallyEdited
            }
        } catch {
            errorText = CommandRouter.ipcError(error).message
            return .failed
        }
    }

    /// Before the selection moves away or 再生成 runs: with unsaved edits ask 保存 / 破棄 / キャンセル (I5).
    /// 保存 runs the normal save, including the overwrite question. True means go ahead.
    private func confirmLeave() async -> Bool {
        guard isDirty else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "議事録の変更が保存されていません"
        alert.informativeText = "保存しますか？ 破棄すると変更は失われます。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "破棄")
        alert.addButton(withTitle: "キャンセル")
        alert.buttons[1].hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            switch await save(overwrite: false, askOverwrite: false) {
            case .saved: return true
            case .failed: return false
            case .externallyEdited:
                let ask = NSAlert()
                ask.alertStyle = .warning
                ask.messageText = "Vault の会議ファイルがアプリの外で編集されています。上書きしますか？"
                ask.addButton(withTitle: "上書きする")
                ask.addButton(withTitle: "キャンセル")
                ask.buttons[0].hasDestructiveAction = true
                guard ask.runModal() == .alertFirstButtonReturn else { return false }
                return await save(overwrite: true, askOverwrite: false) == .saved
            }
        case .alertSecondButtonReturn:
            draft = original.map(EditableMinutes.init)
            return true
        default:
            return false
        }
    }

    private func delete() async {
        await model.perform(.delete(id))
        if model.lastError == nil, model.selectedMeetingID == id { model.selectedMeetingID = nil }
        await model.refresh()
    }

    /// Ruling X38: 「Obsidian で開く」 only when something handles `obsidian://`. Checked once per launch.
    @MainActor private static let obsidianInstalled =
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "obsidian://open")!) != nil

    private static let empty = MinutesOutput(title: "", summary: [], decisions: [], agenda: [], nextActions: [], suggestedTerms: [])
}

/// `transcript_only` and `failed` (§8.4): no minutes yet, the failure band with what helps, and the final
/// transcript below.
struct MinutesMissingView: View {
    let env: AppEnvironment
    let model: AppModel
    let shell: AppShell
    let row: MeetingRow
    @State private var transcript: [LiveLine] = []

    var body: some View {
        VStack(spacing: 0) {
            FailureBand(env: env, model: model, shell: shell, row: row, item: queueItem)
            if transcript.isEmpty {
                ContentUnavailableView("確定版の文字起こしはありません", systemImage: "text.alignleft")
                    .frame(maxHeight: .infinity)
            } else {
                Text(FailureExplanation.transcriptAvailableNote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                Divider()
                LiveTranscriptView(lines: transcript, follows: false)
            }
        }
        .task(id: row.id) {
            let t = try? await env.ports.meetings.transcript(MeetingID(rawValue: row.id), kind: .final)
            transcript = LiveTranscriptView.lines(t?.utterances ?? [])
        }
    }

    private var queueItem: QueueItemDTO? {
        model.queue.items.first { $0.meetingID == row.id && $0.state != JobState.done.rawValue }
    }
}

/// The transcript inside an outer scroll view: plain rows, no own scrolling.
private struct TranscriptList: View {
    let lines: [LiveLine]

    var body: some View {
        if lines.isEmpty {
            Text("（なし）").foregroundStyle(.secondary)
        } else {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    TranscriptLineView(line: line)
                }
            }
            .textSelection(.enabled)
        }
    }
}
