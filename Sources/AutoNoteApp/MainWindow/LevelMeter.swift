import SwiftUI

/// The recording meter: five bars, the first `bars` lit. It redraws only when `bars` changes (once a second at most).
struct LevelMeter: View {
    let bars: Int
    static let count = 5

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<Self.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < bars ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: CGFloat(4 + i * 2))
            }
        }
        .frame(height: 12, alignment: .bottom)
        .accessibilityElement()
        .accessibilityLabel("入力レベル")
        .accessibilityValue("\(min(max(bars, 0), Self.count)) / \(Self.count)")
    }
}
