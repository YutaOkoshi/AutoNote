import AutoNoteCore
import SwiftUI

/// Edits the title and every section of the minutes (3-line summary, decisions, agenda, Next Action with owner and
/// due date). The `t` timestamps are kept as they are.
struct MinutesEditor: View {
    @Binding var minutes: MinutesOutput
    /// 「ファイル名も変更する」 under the title; nil hides it (the title is unchanged).
    var renameFile: Binding<Bool>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("タイトル", text: $minutes.title)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            if let renameFile {
                Toggle("ファイル名も変更する", isOn: renameFile)
            }

            section("3 行要約") {
                ForEach(minutes.summary.indices, id: \.self) { i in
                    TextField("要約 \(i + 1)", text: $minutes.summary[i], axis: .vertical)
                }
            }

            section("決定事項") {
                if minutes.decisions.isEmpty { empty }
                ForEach(minutes.decisions.indices, id: \.self) { i in
                    row(time: minutes.decisions[i].t, remove: { minutes.decisions.remove(at: i) }) {
                        TextField("決定事項", text: $minutes.decisions[i].text, axis: .vertical)
                    }
                }
            }

            section("議題") {
                if minutes.agenda.isEmpty { empty }
                ForEach(minutes.agenda.indices, id: \.self) { i in
                    row(time: minutes.agenda[i].t, remove: { minutes.agenda.remove(at: i) }) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("議題", text: $minutes.agenda[i].title).bold()
                            TextField("内容", text: $minutes.agenda[i].body, axis: .vertical)
                        }
                    }
                }
            }

            section("Next Action") {
                if minutes.nextActions.isEmpty { empty }
                ForEach(minutes.nextActions.indices, id: \.self) { i in
                    row(time: minutes.nextActions[i].t, remove: { minutes.nextActions.remove(at: i) }) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("内容", text: $minutes.nextActions[i].text, axis: .vertical)
                            HStack {
                                TextField("担当", text: optional($minutes.nextActions[i].owner))
                                TextField("期限", text: optional($minutes.nextActions[i].due))
                            }
                        }
                    }
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private var empty: some View { Text("（なし）").foregroundStyle(.secondary) }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func row<C: View>(time: String, remove: @escaping () -> Void, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(time).font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.top, 4)
            content()
            Button("削除", systemImage: "minus.circle") { remove() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("この項目を削除")
        }
    }

    /// An empty field stands for nil (the schema writes `null`).
    private func optional(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}
