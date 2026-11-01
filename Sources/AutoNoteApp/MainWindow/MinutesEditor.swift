import AutoNoteCore
import Foundation
import SwiftUI

/// The 編集 tab: edits the title and the v1 sections (summary, decisions, agenda, actions with owner and due date);
/// the v2 sections (attendees, key points, questions, deadlines, follow-ups, risks, insights, diagram) can only be
/// removed item by item. The `t` timestamps and every other key are kept as they are (`EditableMinutes`).
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

            section("要約") {
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

            section("アクション") {
                if minutes.nextActions.isEmpty { empty }
                ForEach($minutes.nextActions) { $item in
                    row(time: item.value.t, remove: { minutes.nextActions.removeAll { $0.id == item.id } }) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("優先度 \(MinutesPresentation.levelText(item.value.priority))")
                                    .font(.caption).foregroundStyle(.secondary)
                                TextField("内容", text: $item.value.text, axis: .vertical)
                            }
                            HStack {
                                TextField("担当", text: optional($item.value.owner))
                                TextField("期限", text: optional($item.value.due))
                            }
                        }
                    }
                }
            }

            // v2: remove only (no add or edit in this version).
            removable("出席者", $minutes.attendees) { a in
                Text(a.role.map { "\(a.name)（\($0)）" } ?? a.name)
            }
            removable("重要ポイント", $minutes.keyPoints, time: \.t) { Text($0.text) }
            removable("質問", $minutes.questions, time: \.t) { q in
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.question)
                    Text([q.askedBy, q.isResolved ? MinutesPresentation.resolvedText : MinutesPresentation.unresolvedText,
                          q.answer.map { "→ \($0)" }].compactMap { $0 }.joined(separator: "　"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            removable("締め切り", $minutes.deadlines, time: \.t) { d in
                Text("\(d.description) — \(d.date)\(d.owner.map { "（\($0)）" } ?? "")")
            }
            removable("フォローアップ", $minutes.followUps, time: \.t) { Text($0.text) }
            removable("リスク", $minutes.risks, time: \.t) { r in
                Text("重大度 \(MinutesPresentation.levelText(r.severity))　\(r.description)\(r.mitigation.map { " — 対策: \($0)" } ?? "")")
            }
            removable("インサイト", $minutes.insights, time: \.t) { Text($0.text) }
            if let diagram = minutes.architectureDiagram {
                section("構成図") {
                    HStack(alignment: .top, spacing: 8) {
                        Text(diagram).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        removeButton { minutes.architectureDiagram = nil }
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
            removeButton(remove)
        }
    }

    private func removeButton(_ remove: @escaping () -> Void) -> some View {
        Button("削除", systemImage: "minus.circle") { remove() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("この項目を削除")
    }

    /// A v2 section shown read-only with a remove button per item; hidden when empty.
    @ViewBuilder
    private func removable<Value: Equatable & Sendable, C: View>(
        _ title: String, _ items: Binding<[EditableItem<Value>]>, time: KeyPath<Value, String>? = nil,
        @ViewBuilder _ content: @escaping (Value) -> C
    ) -> some View {
        if !items.wrappedValue.isEmpty {
            section(title) {
                ForEach(items.wrappedValue) { item in
                    HStack(alignment: .top, spacing: 8) {
                        if let time {
                            Text(item.value[keyPath: time]).font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.top, 2)
                        }
                        content(item.value).frame(maxWidth: .infinity, alignment: .leading)
                        removeButton { items.wrappedValue.removeAll { $0.id == item.id } }
                    }
                }
            }
        }
    }

    /// An empty field stands for nil (the schema writes `null`).
    private func optional(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}
