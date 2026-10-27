import Foundation

/// How long a meeting was, in the words the list and the bands use.
public enum DurationText {
    /// Seconds under a minute ("32 秒"), otherwise minutes ("4 分"); nil when neither is known.
    public static func list(seconds: Int?, minutes: Int?) -> String? {
        if let seconds, seconds < 60 { return "\(max(0, seconds)) 秒" }
        if let minutes { return "\(minutes) 分" }
        if let seconds { return "\(seconds / 60) 分" }
        return nil
    }

    /// "32 秒" under a minute, "4 分 12 秒" from a minute, "2 分" on a whole minute.
    public static func spoken(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s) 秒" }
        return s % 60 == 0 ? "\(s / 60) 分" : "\(s / 60) 分 \(s % 60) 秒"
    }
}

/// The band for a recording under a minute, which is not processed on its own.
public enum ShortRecordingCopy {
    public static func band(seconds: Int?) -> String {
        guard let seconds else { return "1 分未満の録音です。自動では処理しません。文字起こしと議事録を作りますか？" }
        return "\(seconds) 秒の録音です。1 分未満なので自動では処理しません。文字起こしと議事録を作りますか？"
    }

    public static let transcribeTitle = "作る"
    public static let discardTitle = "削除"
}

/// What the window says while a meeting is being turned into minutes.
public enum ProcessingPresentation {
    public static let explainer = "文字起こし → 議事録の作成 → 保存 の順に進みます。終わると議事録がここに開きます。"

    /// The heading for a queue stage (`JobStage` raw value).
    public static func heading(stage: String) -> String {
        switch stage {
        case "transcribe": "文字起こし中…"
        case "summarize": "議事録を作成中…"
        case "write_vault", "update_index", "automations": "保存中…"
        default: "処理中…"
        }
    }

    /// Which engine is transcribing; only for the transcribe stage.
    public static func engineNote(stage: String, model: Readiness.Model) -> String? {
        guard stage == "transcribe" else { return nil }
        switch model {
        case .installed(let name): return "whisper \(name)"
        case .downloading: return "Apple 音声入力（whisper はダウンロード中）"
        case .none, .failed: return "Apple 音声入力"
        }
    }

    public static func stoppedBand(seconds: Int) -> String { "録音を保存しました（\(DurationText.spoken(seconds))）" }

    /// The saved path with the home folder shown as `~`.
    public static func savedBand(path: String, home: String) -> String {
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        let shown = !trimmedHome.isEmpty && path.hasPrefix(trimmedHome + "/") ? "~" + path.dropFirst(trimmedHome.count) : path
        return "議事録を保存しました — \(shown)"
    }
}

/// The main window's toolbar buttons for each recorder state.
public enum MainToolbar {
    public static func actions(for state: RecorderState) -> [UserAction] {
        switch state {
        case .idle: [.start]
        case .countdown: [.cancelCountdown]
        case .recording, .grace: [.stop]
        case .paused: [.stop, .resume]
        }
    }
}
