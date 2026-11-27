import Foundation

/// The wording for a recording that is missing audio (`manifest.audio_loss`): the meeting list row and the note.
public enum AudioLossPresentation {
    public static func trackName(_ track: Track) -> String {
        switch track {
        case .mic: "マイク"
        case .system: "システム音声"
        }
    }

    /// 「システム音声 約 12 分、マイク 45 秒」; nil without a loss.
    public static func detail(_ losses: [TrackLoss]?) -> String? {
        guard let losses, !losses.isEmpty else { return nil }
        return losses.map { loss in
            let name = trackName(loss.track)
            if loss.seconds >= 60 { return "\(name) 約 \(Int((Double(loss.seconds) / 60).rounded())) 分" }
            if loss.seconds > 0 { return "\(name) \(loss.seconds) 秒" }
            return "\(name)（録音できませんでした）"
        }.joined(separator: "、")
    }

    /// The meeting list row: 「録音の欠損: システム音声 約 12 分」.
    public static func rowLabel(_ losses: [TrackLoss]?) -> String? {
        detail(losses).map { "録音の欠損: \($0)" }
    }

    /// One line at the top of the meeting note. The wording stays at "may": another app playing digital silence
    /// looks the same as audio that did not arrive.
    public static func noteLine(_ losses: [TrackLoss]?) -> String? {
        detail(losses).map { "> 録音が一部欠けている可能性があります（\($0)）。その間の発言は文字起こしと議事録に入っていません。" }
    }
}
