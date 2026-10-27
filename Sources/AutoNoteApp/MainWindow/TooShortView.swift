import AutoNoteCore
import SwiftUI

/// A recording under a minute (§5.9): its length; the choice (作る / 削除) is in the band above.
struct TooShortView: View {
    let row: MeetingRow

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "timer").font(.largeTitle).foregroundStyle(.secondary)
            if let seconds = row.durationSeconds {
                Text("\(DurationText.spoken(seconds))の録音です").font(.title3)
            } else {
                Text("1 分未満の録音です").font(.title3)
            }
            Text("上の帯から選んでください").foregroundStyle(.secondary)
        }
        .padding(24)
    }
}
