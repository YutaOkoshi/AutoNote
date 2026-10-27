import AutoNoteCore
import SwiftUI

/// 議事録: `_autonote/prompt.md` (§8.3) and `_autonote/frontmatter.md` (§9.2) as plain text. Read again when the tab
/// appears and when the window comes to the front, unless there are unsaved edits.
struct MinutesTab: View {
    let env: AppEnvironment

    @State private var prompt = ""
    @State private var frontmatter = ""
    @State private var baseline: (prompt: String, frontmatter: String)?
    @State private var saveState: SaveState = .idle

    private var isDirty: Bool {
        guard let baseline else { return false }
        return prompt != baseline.prompt || frontmatter != baseline.frontmatter
    }

    private var requiredKeysNote: String {
        "\(FrontmatterTemplate.requiredKeys.joined(separator: "・")) はテンプレートから消しても必ず付きます"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("プロンプト").font(.headline)
            TextEditor(text: $prompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .border(.separator)
            Text("Claude Code へ渡す指示文です。空にすると既定の指示文に戻ります。")
                .font(.caption).foregroundStyle(.secondary)
            Text("frontmatter テンプレート").font(.headline).padding(.top, 8)
            TextEditor(text: $frontmatter)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .border(.separator)
            Text(requiredKeysNote).font(.caption).foregroundStyle(.secondary)
            HStack {
                if isDirty { Text("未保存の変更があります").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("読み直す") { Task { await reload(force: true) } }
            }
        }
        .padding()
        .safeAreaInset(edge: .bottom) {
            SaveBar(state: saveState, disabled: baseline == nil) { save() }
        }
        .task { await reload(force: false) }
        .onWindowBecameKey { Task { await reload(force: false) } }
    }

    /// Unsaved edits are never overwritten except by 「読み直す」, also when typing started during the read.
    private func reload(force: Bool) async {
        guard force || !isDirty else { return }
        let before = (prompt, frontmatter)
        do {
            let store = await env.output.portable()
            let p = try await store.read(.prompt).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let f = try await store.read(.frontmatter).map { String(decoding: $0, as: UTF8.self) }
                ?? FrontmatterTemplate.defaultText
            guard force || (prompt, frontmatter) == before else { return }
            prompt = p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? DefaultPrompt.instructions : p
            frontmatter = f
            baseline = (prompt, frontmatter)
            if force { saveState = .idle }
        } catch {
            saveState = .failed("_autonote/ を読めません（\((error as NSError).localizedDescription)）")
        }
    }

    /// Writes only what was edited. A prompt cleared to empty is written empty, so the summarizer keeps using the
    /// built-in default (`SummarizeStage` treats an empty `prompt.md` as `DefaultPrompt.instructions`); the default
    /// shown for an empty file is never copied into it.
    private func save() {
        guard let baseline else { return }
        let promptEdited = prompt != baseline.prompt, frontmatterEdited = frontmatter != baseline.frontmatter
        let cleared = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let p = cleared ? "" : prompt
        let f = frontmatter
        Task {
            do {
                let store = await env.output.portable()
                if promptEdited { try await store.write(.prompt, Data(p.utf8)) }
                if frontmatterEdited { try await store.write(.frontmatter, Data(f.utf8)) }
                let shown = cleared ? DefaultPrompt.instructions : p
                prompt = shown
                self.baseline = (shown, f)
                saveState = .saved
            } catch {
                saveState = .failed("_autonote/ に書き込めません（\((error as NSError).localizedDescription)）")
            }
        }
    }
}
