import AutoNoteCore
import Foundation
import SwiftUI

/// One editable list item with a stable identity, so a row can be removed without index-based bindings.
struct EditableItem<Value: Equatable>: Identifiable, Equatable {
    let id = UUID()
    var value: Value
}

/// `MinutesOutput` as the editor edits it: the list sections carry stable identities.
struct EditableMinutes: Equatable {
    var title: String
    var summary: [EditableItem<String>]
    var decisions: [EditableItem<Decision>]
    var agenda: [EditableItem<AgendaItem>]
    var nextActions: [EditableItem<NextAction>]
    var suggestedTerms: [String]

    init(_ m: MinutesOutput) {
        title = m.title
        summary = m.summary.map { EditableItem(value: $0) }
        decisions = m.decisions.map { EditableItem(value: $0) }
        agenda = m.agenda.map { EditableItem(value: $0) }
        nextActions = m.nextActions.map { EditableItem(value: $0) }
        suggestedTerms = m.suggestedTerms
    }

    var minutes: MinutesOutput {
        MinutesOutput(title: title, summary: summary.map(\.value), decisions: decisions.map(\.value),
                      agenda: agenda.map(\.value), nextActions: nextActions.map(\.value), suggestedTerms: suggestedTerms)
    }
}

/// Edits the title and every section of the minutes (3-line summary, decisions, agenda, Next Action with owner and
/// due date). The `t` timestamps are kept as they are.
struct MinutesEditor: View {
    @Binding var minutes: EditableMinutes
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
                ForEach(Array($minutes.summary.enumerated()), id: \.element.id) { offset, $line in
                    TextField("要約 \(offset + 1)", text: $line.value, axis: .vertical)
                }
            }

            section("決定事項") {
                if minutes.decisions.isEmpty { empty }
                ForEach($minutes.decisions) { $item in
                    row(time: item.value.t, remove: { minutes.decisions.removeAll { $0.id == item.id } }) {
                        TextField("決定事項", text: $item.value.text, axis: .vertical)
                    }
                }
            }

            section("議題") {
                if minutes.agenda.isEmpty { empty }
                ForEach($minutes.agenda) { $item in
                    row(time: item.value.t, remove: { minutes.agenda.removeAll { $0.id == item.id } }) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("議題", text: $item.value.title).bold()
                            TextField("内容", text: $item.value.body, axis: .vertical)
                        }
                    }
                }
            }

            section("Next Action") {
                if minutes.nextActions.isEmpty { empty }
                ForEach($minutes.nextActions) { $item in
                    row(time: item.value.t, remove: { minutes.nextActions.removeAll { $0.id == item.id } }) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("内容", text: $item.value.text, axis: .vertical)
                            HStack {
                                TextField("担当", text: optional($item.value.owner))
                                TextField("期限", text: optional($item.value.due))
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
