import AutoNoteCore
import SwiftUI

/// A meeting with minutes: the editor, the bookmarks, the final transcript (read-only, §9.4) and the actions.
struct CompletedDetailView: View {
    let env: AppEnvironment
    let model: AppModel
    let row: MeetingRow

    @State private var original: MinutesOutput?
    @State private var draft: MinutesOutput?
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
            actions
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    }
                    if draft != nil {
                        // §9.1: the rename box shows once the title changed, off by default.
                        MinutesEditor(minutes: Binding(get: { draft ?? Self.empty }, set: { draft = $0 }),
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
        .alert("Vault の会議ファイルがアプリの外で編集されています。上書きしますか？", isPresented: $confirmOverwrite) {
            Button("上書きする", role: .destructive) { Task { await save(overwrite: true) } }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private var titleChanged: Bool {
        guard let original, let draft else { return false }
        return original.title != draft.title
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("保存", systemImage: "square.and.arrow.down.on.square") { Task { await save(overwrite: false) } }
                .disabled(draft == nil || draft == original || saving)
                .keyboardShortcut("s")
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("再生成", systemImage: "arrow.clockwise") { Task { await model.perform(.regenerate(id)) } }
            Button("Obsidian で開く", systemImage: "arrow.up.forward.app") {
                guard let path = row.filePath else { return }
                Task { await WorkspaceOpener().open(URL(filePath: path)) }
            }
            .disabled(row.filePath == nil)
            // No `role: .destructive` here: on macOS 26 it kept the click from reaching the action in Step 3; the
            // confirmation below carries the destructive button.
            Button("この会議を削除", systemImage: "trash") { confirmDelete = true }
                .foregroundStyle(.red)
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
            draft = minutes
            bookmarks = (try? await meetings.manifest(id))?.bookmarks ?? []
            transcript = LiveTranscriptView.lines(try await meetings.transcript(id, kind: .final)?.utterances ?? [])
            renameFile = false
            message = nil
            errorText = nil
        } catch {
            errorText = CommandRouter.ipcError(error).message
        }
    }

    private func save(overwrite: Bool) async {
        guard let draft else { return }
        saving = true
        defer { saving = false }
        do {
            switch try await env.ports.meetings.saveMinutes(id, draft, renameFile: titleChanged && renameFile, overwrite: overwrite) {
            case .saved:
                original = draft
                renameFile = false
                message = "保存しました"
                errorText = nil
                await model.refresh()
            case .externallyEdited:
                confirmOverwrite = true
            }
        } catch {
            errorText = CommandRouter.ipcError(error).message
        }
    }

    private func delete() async {
        await model.perform(.delete(id))
        if model.lastError == nil, model.selectedMeetingID == id { model.selectedMeetingID = nil }
        await model.refresh()
    }

    private static let empty = MinutesOutput(title: "", summary: [], decisions: [], agenda: [], nextActions: [], suggestedTerms: [])
}

/// `transcript_only` and `failed` (§8.4): no minutes yet, 再実行, and the final transcript below.
struct MinutesMissingView: View {
    let env: AppEnvironment
    let model: AppModel
    let row: MeetingRow
    @State private var transcript: [LiveLine] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("議事録 未生成", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                if row.state == .failed {
                    Text(row.state.displayText(progressLabel: row.progressLabel)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("再実行", systemImage: "arrow.clockwise") {
                    Task { await model.perform(.notice(.retry(MeetingID(rawValue: row.id)))) }
                }
            }
            .padding(12)
            Divider()
            if transcript.isEmpty {
                ContentUnavailableView("確定版の文字起こしはありません", systemImage: "text.alignleft")
                    .frame(maxHeight: .infinity)
            } else {
                LiveTranscriptView(lines: transcript, follows: false)
            }
        }
        .task(id: row.id) {
            let t = try? await env.ports.meetings.transcript(MeetingID(rawValue: row.id), kind: .final)
            transcript = LiveTranscriptView.lines(t?.utterances ?? [])
        }
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
