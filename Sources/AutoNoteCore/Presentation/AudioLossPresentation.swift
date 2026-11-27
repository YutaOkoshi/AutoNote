import Foundation

/// The wording for a recording that is missing audio (`manifest.audio_loss`): the meeting list row and the note.
///
/// How sure the wording is depends on the kind of loss. Suspect seconds of system audio are a possibility: an app
/// that plays digital silence looks the same as audio that did not arrive. A microphone without callbacks and a
/// failed track are facts.
public enum AudioLossPresentation {
    public static func trackName(_ track: Track) -> String {
        switch track {
        case .mic: "マイク"
        case .system: "システム音声"
        }
    }

    /// 「約 12 分」 from a minute on, 「45 秒」 below.
    static func duration(_ seconds: Int) -> String {
        seconds >= 60 ? "約 \(Int((Double(seconds) / 60).rounded())) 分" : "\(seconds) 秒"
    }

    /// 「システム音声 約 12 分、マイク 45 秒」; nil without a loss. A failed track lost everything after the failure,
    /// which its counted seconds do not show, so the failure is said instead of them.
    public static func detail(_ losses: [TrackLoss]?) -> String? {
        guard let losses, !losses.isEmpty else { return nil }
        return losses.map { loss in
            let name = trackName(loss.track)
            return loss.sourceFailed ? "\(name)（録音に失敗）" : "\(name) \(duration(loss.seconds))"
        }.joined(separator: "、")
    }

    /// Nothing but suspect seconds of system audio.
    private static func isOnlyPossible(_ losses: [TrackLoss]) -> Bool {
        losses.allSatisfy { $0.track == .system && !$0.sourceFailed }
    }

    /// The meeting list row: 「録音の欠損の可能性: システム音声 約 12 分」, 「録音の欠損: マイク 45 秒」.
    public static func rowLabel(_ losses: [TrackLoss]?) -> String? {
        guard let losses, let detail = detail(losses) else { return nil }
        return "\(isOnlyPossible(losses) ? "録音の欠損の可能性" : "録音の欠損"): \(detail)"
    }

    /// Per lossy track: whose voice, how sure, and what is missing from the transcript and the minutes.
    static func sentences(_ losses: [TrackLoss]?) -> [String] {
        (losses ?? []).map { loss in
            let name = trackName(loss.track)
            let (whose, voice) = loss.track == .mic ? ("自分の", "自分の声") : ("相手の", "相手の声")
            if loss.sourceFailed {
                return "\(name)（\(voice)）の録音に失敗しました。失敗した後の\(whose)発言は文字起こしと議事録に入っていません。"
            }
            switch loss.track {
            case .mic:
                return "\(name)（\(voice)）が \(duration(loss.seconds))、録音されていません。その間の\(whose)発言は文字起こしと議事録に入っていません。"
            case .system:
                // No space before 「約」: "が約 12 分".
                let length = loss.seconds >= 60 ? duration(loss.seconds) : " \(duration(loss.seconds))"
                return "\(name)（\(voice)）が\(length)、録音に入っていない可能性があります。その間に相手が話していた場合、その発言は文字起こしと議事録に入っていません。"
            }
        }
    }

    /// The lines at the top of the meeting note, one per lossy track.
    public static func noteLine(_ losses: [TrackLoss]?) -> String? {
        let lines = sentences(losses)
        return lines.isEmpty ? nil : lines.map { "> \($0)" }.joined(separator: "\n")
    }

    /// The same sentences for the row's tooltip.
    public static func help(_ losses: [TrackLoss]?) -> String? {
        let lines = sentences(losses)
        return lines.isEmpty ? nil : lines.joined()
    }
}
