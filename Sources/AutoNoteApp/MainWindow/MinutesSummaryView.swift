import AutoNoteCore
import SwiftUI

/// The 「要約」 tab: draws `MinutesPresentation.sections` read-only. A row's time jumps to that utterance in the
/// 「文字起こし」 tab (`onJump`).
struct MinutesSummaryView: View {
    let minutes: MinutesOutput
    let onJump: (TimelineTime) -> Void

    @State private var filter: MinutesActionFilter = .all
    @State private var openAgenda: Set<String> = []
    @State private var previewDiagram: PreviewDiagram?

    private var sections: [MinutesSection] { MinutesPresentation.sections(minutes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(minutes.title.isEmpty ? "（無題）" : minutes.title)
                .font(.title2.bold())
                .textSelection(.enabled)
            if sections.isEmpty {
                Text("議事録の項目はありません").foregroundStyle(.secondary)
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    heading(section)
                    content(section)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $previewDiagram) { d in MermaidPreviewSheet(source: d.source) }
    }

    private func heading(_ section: MinutesSection) -> some View {
        HStack(spacing: 6) {
            Label(section.title, systemImage: section.symbol).font(.headline)
            if section.kind == .actions {
                Text(MinutesPresentation.countText(section.rows.count)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("優先度", selection: $filter) {
                    ForEach(MinutesActionFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func content(_ section: MinutesSection) -> some View {
        switch section.kind {
        case .attendees:
            FlowLayout(spacing: 6) {
                ForEach(section.rows) { attendeeChip($0) }
            }
        case .agenda:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { i, row in agendaRow(i + 1, row) }
            }
        case .summary:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(section.rows) { Text($0.text).fixedSize(horizontal: false, vertical: true) }
            }
            .textSelection(.enabled)
        case .diagram:
            diagram(section.diagram ?? "")
        case .actions:
            let rows = MinutesPresentation.filter(section.rows, by: filter)
            VStack(alignment: .leading, spacing: 6) {
                if rows.isEmpty { Text(MinutesPresentation.emptyFilterText).foregroundStyle(.secondary) }
                ForEach(rows) { actionRow($0) }
            }
        case .keyPoints:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(section.rows) { row in
                    line(row) { Text("•").foregroundStyle(.secondary) }
                }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(section.rows) { row in
                    line(row) { icon(row) }
                }
            }
        }
    }

    // MARK: - Rows

    private func attendeeChip(_ row: MinutesRow) -> some View {
        HStack(spacing: 4) {
            Image(systemName: row.symbol ?? "person.fill").foregroundStyle(.secondary)
            Text(row.text)
            if let role = row.secondary { Text(role).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private func agendaRow(_ number: Int, _ row: MinutesRow) -> some View {
        let open = openAgenda.contains(row.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button {
                    if open { openAgenda.remove(row.id) } else { openAgenda.insert(row.id) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.caption).foregroundStyle(.secondary).frame(width: 10)
                        Text("\(number). \(row.text)").bold()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(row.detail == nil)
                timeButton(row)
            }
            if open, let detail = row.detail {
                Text(detail)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 16)
            }
        }
    }

    private func actionRow(_ row: MinutesRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ForEach(Array(row.badges.enumerated()), id: \.offset) { _, b in badge(b) }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.text).fixedSize(horizontal: false, vertical: true)
                if let s = row.secondary { Text(s).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            timeButton(row)
        }
    }

    /// Icon, text, then the second line (secondary text and badges) and the detail; the time at the right end.
    private func line<Leading: View>(_ row: MinutesRow, @ViewBuilder leading: () -> Leading) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            leading().frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.text).fixedSize(horizontal: false, vertical: true)
                if row.secondary != nil || !row.badges.isEmpty {
                    HStack(spacing: 6) {
                        if let s = row.secondary {
                            Text(s).font(.caption).foregroundStyle(row.secondaryTone.map(color) ?? .secondary)
                        }
                        ForEach(Array(row.badges.enumerated()), id: \.offset) { _, b in badge(b) }
                    }
                }
                if let detail = row.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            timeButton(row)
        }
    }

    @ViewBuilder
    private func icon(_ row: MinutesRow) -> some View {
        if let symbol = row.symbol {
            Image(systemName: symbol).foregroundStyle(row.symbolTone.map(color) ?? .secondary)
        }
    }

    private func badge(_ b: MinutesBadge) -> some View {
        Text(b.text)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color(b.tone))
            .background(Capsule().fill(color(b.tone).opacity(0.15)))
    }

    @ViewBuilder
    private func timeButton(_ row: MinutesRow) -> some View {
        if let time = row.time, let text = row.timeText {
            Button(text) { onJump(time) }
                .buttonStyle(.link)
                .font(.caption.monospacedDigit())
                .help("文字起こしのこの発言へ移る")
        }
    }

    private func diagram(_ source: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(source)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            Button(MinutesPresentation.previewLabel, systemImage: "eye") { previewDiagram = PreviewDiagram(source: source) }
        }
    }

    private func color(_ tone: MinutesTone) -> Color {
        switch tone {
        case .red: .red
        case .orange: .orange
        case .blue: .blue
        case .green: .green
        case .yellow: .yellow
        case .secondary: .secondary
        }
    }

    private struct PreviewDiagram: Identifiable {
        let id = UUID()
        let source: String
    }
}

/// Lays chips out left to right, wrapping to the next line when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(i)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
