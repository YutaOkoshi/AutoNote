import AutoNoteCore
import Foundation
import SwiftUI

/// The detail column when there are no meetings, nothing is selected and nothing is recording:
/// how to record, how to import, what happens after stopping, and the readiness card at the bottom.
struct EmptyStateView: View {
    let model: AppModel
    let shell: AppShell

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                // The menu-bar icon itself (SF Symbol `waveform`), inline; read aloud as the AutoNote icon.
                Text("録音はメニューバーの \(Image(systemName: "waveform")) か、上の「録音を開始」から")
                    .font(.title3)
                    .accessibilityLabel("録音はメニューバーの AutoNote アイコンか、上の「録音を開始」から")
                VStack(spacing: 4) {
                    Text("音声ファイルをここへドラッグすると取り込めます")
                    Text("止めると文字起こしと議事録が自動でできます（1 分未満の録音は、止めたあとに「作る」で）。")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            Spacer()
            ReadinessCard(model: model, shell: shell)
                .padding(16)
        }
    }
}

/// The three readiness rows: title on the left, status and ✓ or the row's buttons on the right.
struct ReadinessCard: View {
    let model: AppModel
    let shell: AppShell

    var body: some View {
        let rows = ReadinessPresentation.rows(model.readiness, home: NSHomeDirectory())
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.item) { index, row in
                if index > 0 { Divider() }
                HStack(spacing: 8) {
                    Text(row.title).bold()
                    Spacer(minLength: 12)
                    Text(row.status)
                        .foregroundStyle(row.ready ? .primary : .secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                    if row.ready {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("準備できています")
                    } else {
                        ForEach(row.actions, id: \.self) { action in
                            ReadinessActionButton(action: action, model: model, shell: shell)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: 560)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}
