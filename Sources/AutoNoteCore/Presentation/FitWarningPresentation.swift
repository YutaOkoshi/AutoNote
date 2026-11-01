import Foundation

/// The wording of a `FitWarning`, shared by the readiness card, its band and the settings screen.
public enum FitWarningPresentation {
    /// The readiness row's title: which step, with the model.
    public static func title(_ w: FitWarning) -> String {
        switch w {
        case .finalTooSlow(let m), .finalLowMemory(let m): "停止後の処理（whisper \(m)）"
        case .liveTooSlow(let m): "ライブ文字起こし（whisper \(m)）"
        }
    }

    /// The readiness row's short status.
    public static func status(_ w: FitWarning) -> String {
        switch w {
        case .finalTooSlow: "録音の 1〜1.3 倍の時間、CPU をほぼ使い切ります"
        case .finalLowMemory: "メモリが足りずスワップが増えます"
        case .liveTooSlow: "リアルタイムに追いつきません"
        }
    }

    /// One sentence with the reason and the remedy: the band, and the note under the settings picker.
    public static func message(_ w: FitWarning) -> String {
        switch w {
        case .finalTooSlow(let m):
            "この Mac（Intel）では whisper \(m) の確定版の文字起こしに録音と同じ〜1.3 倍の時間がかかり、そのあいだ CPU をほぼ使い切ります。small なら約半分の時間です"
        case .finalLowMemory(let m):
            "この Mac のメモリでは whisper \(m) の処理中にメモリが足りず、スワップが増えます（16 GB 以上を推奨）。large-v3-turbo-q5_0 なら同じ精度でメモリは約半分です"
        case .liveTooSlow(let m):
            "この Mac（Intel）では whisper \(m) のライブ文字起こしがリアルタイムに追いつきません（確定版の 4 スレッドでも録音の 1.31 倍かかった実測があります）。リアルタイムは Apple の音声入力を推奨します"
        }
    }
}
