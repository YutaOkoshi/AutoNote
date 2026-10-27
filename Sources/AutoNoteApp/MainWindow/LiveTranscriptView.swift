import AutoNoteCore
import SwiftUI

/// Transcript lines (§6.3): time, speaker and text; partial results in the secondary colour; markers as separator
/// lines. With `follows`, the view stays on the newest line until the user scrolls up, then offers 「最新へ」.
struct LiveTranscriptView: View {
    let lines: [LiveLine]
    var follows = true

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var following = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    TranscriptLineView(line: line)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(follows ? .bottom : .top)
        .onScrollGeometryChange(for: ScrollState.self) { g in
            ScrollState(offset: g.contentOffset.y, contentHeight: g.contentSize.height,
                        atBottom: g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 24)
        } action: { old, new in
            guard follows else { return }
            // Growing content moves nothing; only a scroll at the same content height decides (up: stop, back to the
            // bottom: follow again).
            guard abs(old.contentHeight - new.contentHeight) < 0.5, abs(old.offset - new.offset) > 0.5 else { return }
            following = new.atBottom
        }
        .onChange(of: lines) {
            if follows, following { position.scrollTo(edge: .bottom) }
        }
        .overlay(alignment: .bottomTrailing) {
            if follows, !following {
                Button("最新へ", systemImage: "arrow.down.to.line") {
                    following = true
                    withAnimation { position.scrollTo(edge: .bottom) }
                }
                .buttonStyle(.borderedProminent)
                .padding(12)
            }
        }
    }

    /// The utterances as lines, markers told apart the same way as the live buffer.
    static func lines(_ utterances: [Utterance]) -> [LiveLine] {
        utterances.map { LiveFeed.isMarker($0) ? .marker($0) : .utterance($0) }
    }
}

private struct ScrollState: Equatable {
    var offset: CGFloat
    var contentHeight: CGFloat
    var atBottom: Bool
}

struct TranscriptLineView: View {
    let line: LiveLine

    var body: some View {
        switch line {
        case .utterance(let u):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(u.start.hhmmss)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(u.speaker.displayName)
                    .font(.caption.bold())
                    .frame(width: 36, alignment: .leading)
                Text(u.text)
                    .foregroundStyle(u.isFinal ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .marker(let u):
            HStack(spacing: 6) {
                if u.text != LiveFeed.pauseMarkerText {
                    Image(systemName: "bookmark.fill").foregroundStyle(.orange)
                }
                Text(u.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(u.start.hhmmss)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }
}
