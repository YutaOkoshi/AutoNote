import AutoNoteCore
import SwiftUI

/// 辞書: `_autonote/dictionary.md` as three editable lists (§7.2). Read again when the tab appears and when the
/// window comes to the front, unless there are unsaved edits. Lines `DictionaryFile.parse` could not use are listed
/// at the bottom; the rest of the file still loads (ruling X39).
struct DictionaryTab: View {
    let env: AppEnvironment

    @State private var terms: [EditRow] = []
    @State private var replacements: [EditRow] = []
    @State private var fillers: [EditRow] = []
    /// What was last read or saved, to tell unsaved edits apart.
    @State private var baseline: DictionaryDraft?
    @State private var issues: [DictionaryIssue] = []
    @State private var saveState: SaveState = .idle

    private var draft: DictionaryDraft {
        var d = DictionaryDraft(.default)
        d.terms = terms.map(\.a)
        d.replacements = replacements.map { Replacement(from: $0.a, to: $0.b) }
        d.fillers = fillers.map(\.a)
        return d
    }

    private var isDirty: Bool { baseline != nil && draft != baseline }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    rows($terms, placeholder: "用語（例: AutoNote）")
                    Button("用語を追加", systemImage: "plus") { terms.append(EditRow(a: "")) }
                } header: {
                    Text("用語")
                } footer: {
                    Text("文字起こしのヒントと議事録の表記に使います。").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    ForEach($replacements) { $row in
                        HStack {
                            TextField("誤", text: $row.a, prompt: Text("誤（例: オートノート）")).labelsHidden()
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("正", text: $row.b, prompt: Text("正（例: AutoNote）")).labelsHidden()
                            removeButton { replacements.removeAll { $0.id == row.id } }
                        }
                    }
                    Button("置換を追加", systemImage: "plus") { replacements.append(EditRow(a: "")) }
                } header: {
                    Text("置換")
                }
                Section {
                    rows($fillers, placeholder: "フィラー（例: えー）")
                    Button("フィラーを追加", systemImage: "plus") { fillers.append(EditRow(a: "")) }
                } header: {
                    Text("フィラー")
                } footer: {
                    Text("「フィラーを取り除く」がオンのとき、文字起こしから消します。").font(.caption).foregroundStyle(.secondary)
                }
                if !issues.isEmpty {
                    Section("読めなかった行（保存するとこの行はなくなります）") {
                        ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                            VStack(alignment: .leading) {
                                Text("\(issue.line) 行目: \(issue.text)").font(.callout)
                                Text(issue.reason).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if isDirty { Text("未保存の変更があります").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("読み直す") { Task { await reload(force: true) } }
            }
            .padding(.horizontal)
            SaveBar(state: saveState, disabled: baseline == nil) { save() }
        }
        .task { await reload(force: false) }
        .onWindowBecameKey { Task { await reload(force: false) } }
    }

    private func rows(_ list: Binding<[EditRow]>, placeholder: String) -> some View {
        ForEach(list) { $row in
            HStack {
                TextField(placeholder, text: $row.a, prompt: Text(placeholder)).labelsHidden()
                removeButton { list.wrappedValue.removeAll { $0.id == row.id } }
            }
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button("削除", systemImage: "minus.circle", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
    }

    /// Unsaved edits are never overwritten except by 「読み直す」.
    private func reload(force: Bool) async {
        guard force || !isDirty else { return }
        do {
            let data = try await env.output.portable().read(.dictionary)
            let text = data.map { String(decoding: $0, as: UTF8.self) } ?? DictionaryFile.defaultMarkdown
            let parsed = DictionaryFile.parse(text)
            show(DictionaryDraft(parsed.dictionary))
            issues = parsed.issues
            if force { saveState = .idle }
        } catch {
            saveState = .failed("dictionary.md を読めません（\((error as NSError).localizedDescription)）")
        }
    }

    private func show(_ d: DictionaryDraft) {
        terms = d.terms.map { EditRow(a: $0) }
        replacements = d.replacements.map { EditRow(a: $0.from, b: $0.to) }
        fillers = d.fillers.map { EditRow(a: $0) }
        baseline = draft
    }

    private func save() {
        let current = draft
        Task {
            do {
                let file = try current.toFile()
                try await env.output.portable().write(.dictionary, Data(file.render().utf8))
                show(DictionaryDraft(file))
                issues = []
                saveState = .saved
            } catch let e as AppCommandError {
                saveState = .failed(SettingsSaving.message(e))
            } catch {
                saveState = .failed("dictionary.md に書き込めません（\((error as NSError).localizedDescription)）")
            }
        }
    }
}
