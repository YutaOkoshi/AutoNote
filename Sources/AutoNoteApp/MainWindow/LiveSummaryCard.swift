import AutoNoteCore
import SwiftUI

/// The live summary: what is being discussed now, the decisions and the to-dos, in a band like
/// `StatusHeader`'s. Three parts: a header with 「いま」 and the collapse toggle, a body with the
/// decisions and to-dos that scrolls inside a capped height (its text fades at the foot while more is below), and a
/// footer with the status and 「n 秒前に更新」 that stays visible even when collapsed.
struct LiveSummaryCard: View {
    let content: LiveSummaryCardContent
    /// One preference shared by the recording, processing and minutes-missing screens; expanded by default.
    @AppStorage("live_summary_card_collapsed") private var collapsed = false
    /// The body's own height, so a short summary takes only its rows and a long one stops at the cap.
    @State private var contentHeight: CGFloat = 0
    /// Whether the body is scrolled to its end (then the fade is lifted).
    @State private var atEnd = false

    private static let maxBodyHeight: CGFloat = 220
    private static let fadeHeight: CGFloat = 18
    private static let bandColor = Color.secondary.opacity(0.12)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if !collapsed { scrollingBody }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Self.bandColor)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                title(LiveSummaryPresentation.nowTitle)
                Text(content.now).font(.body.bold()).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Button(action: toggle) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? LiveSummaryPresentation.expandLabel : LiveSummaryPresentation.collapseLabel)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    private var scrollingBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                title(LiveSummaryPresentation.decisionsTitle)
                items(content.decisions)
                title(LiveSummaryPresentation.todosTitle)
                items(content.todos)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollIndicators(.visible)
        .scrollBounceBehavior(.basedOnSize)
        // The content's height, capped (a plain `maxHeight` frame would grow to the cap even for 3 rows).
        .frame(height: min(contentHeight, Self.maxBodyHeight))
        .onScrollGeometryChange(for: Bool.self) { g in
            g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 1
        } action: { _, end in atEnd = end }
        // A body shown again (expanded, or re-created by a meeting switch) starts at the top: not at the end.
        .onAppear { atEnd = false }
        // 「続きがある」: the last 18 pt of text fade out while more is below; lifted at the end so the last row is clear.
        .mask {
            if contentHeight > Self.maxBodyHeight && !atEnd {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fadeHeight)
                }
            } else {
                Color.black
            }
        }
    }

    /// The status (paused / failing) and 「n 秒前に更新」, outside the scroll area; absent when both are nil.
    @ViewBuilder private var footer: some View {
        if content.status != nil || content.updated != nil {
            HStack(spacing: 8) {
                Spacer()
                if let status = content.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                if let updated = content.updated {
                    Text(updated).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func toggle() {
        atEnd = false
        withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    /// One 「・」 row per item (the presentation already turns an empty list into 「（なし）」).
    private func items(_ lines: [String]) -> some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text("・\(line)")
        }
    }
}
