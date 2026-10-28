import AutoNoteCore
import SwiftUI

/// The live summary (plan 09): what is being discussed now, the decisions and the to-dos, in a band like
/// `StatusHeader`'s. Scrolls inside a capped height so a long list never pushes the live transcript away.
struct LiveSummaryCard: View {
    let content: LiveSummaryCardContent
    /// The content's own height, so a short summary takes only its rows and a long one stops at 220 pt.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                title(LiveSummaryPresentation.nowTitle)
                Text(content.now).font(.body.bold())
                title(LiveSummaryPresentation.decisionsTitle)
                items(content.decisions)
                title(LiveSummaryPresentation.todosTitle)
                items(content.todos)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        // The content's height, capped at 220 pt (a plain `maxHeight` frame would grow to the cap even for 3 rows).
        .frame(height: min(contentHeight, 220))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
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
