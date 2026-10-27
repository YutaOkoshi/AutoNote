import Foundation

/// A failed or waiting job, or a summary failure, as one "what — why" sentence plus the buttons that help.
/// Internal identifiers (reason codes, error type names) never reach the text.
public struct FailureExplanation: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case installGuide, redetectClaudeAndRerun, rerun, openSystemSettings, revealAudio, delete, changeOutputFolder, loginGuide
    }

    public enum Tone: Sendable, Equatable { case failure, waiting }

    public enum Source: Sendable, Equatable {
        case job(stage: String, reason: String?, waiting: Bool = false)
        case summary(String?)
    }

    public var what: String
    public var why: String
    public var actions: [Action]
    public var tone: Tone

    public init(what: String, why: String, actions: [Action], tone: Tone) {
        self.what = what
        self.why = why
        self.actions = actions
        self.tone = tone
    }

    public static let transcriptAvailableNote = "文字起こしはできています。議事録は再実行で作れます"
    public static let loginSteps = "ターミナルを開いて claude と入力し、表示に従ってログインしてください。終わったら［再実行］を押します。"

    private static let unknownWhy = "原因がわかりません"

    public static func make(_ source: Source, outputFolderPath: String) -> FailureExplanation {
        switch source {
        case let .summary(raw):
            let what = "議事録を作れませんでした"
            switch SummaryFailureKind.of(raw) {
            case .claudeNotFound:
                return .init(what: what, why: "Claude Code（claude）が見つかりません",
                             actions: [.installGuide, .redetectClaudeAndRerun], tone: .failure)
            case .notLoggedIn:
                return .init(what: what, why: "Claude Code にログインしていません", actions: [.loginGuide, .rerun], tone: .failure)
            case .rateLimited:
                return .init(what: what, why: "Claude Code の利用上限に達しました", actions: [.rerun], tone: .failure)
            case .contextExceeded:
                return .init(what: what, why: "文字起こしが長すぎました", actions: [.rerun], tone: .failure)
            case .timedOut:
                return .init(what: what, why: "Claude Code が時間内に応答しませんでした", actions: [.rerun], tone: .failure)
            case .invalidOutput:
                return .init(what: what, why: "Claude Code の出力を読めませんでした", actions: [.rerun], tone: .failure)
            case .other, nil:
                return .init(what: what, why: unknownWhy, actions: [.rerun], tone: .failure)
            }
        case let .job(stage, reason, waiting):
            let key = reason.map { String($0.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }
            if waiting {
                if let key, key.hasPrefix("output_folder_") {
                    return .init(what: "保存先に書けないので待っています", why: outputFolderPath,
                                 actions: [.changeOutputFolder], tone: .waiting)
                }
                return .init(what: "\(stageName(stage, particle: "を"))待っています", why: "しばらくしてから自動でやり直します",
                             actions: [], tone: .waiting)
            }
            if key == "no_speech" {
                return .init(what: "音声を聞き取れませんでした", why: "録音に声が入っていないか、マイクが拾えていません",
                             actions: [.rerun, .revealAudio, .delete], tone: .failure)
            }
            let why: String
            switch key {
            case "final_transcription_failed": why = "文字起こしエンジンが途中で止まりました"
            case "final_transcript_missing": why = "文字起こしのファイルが見つかりません"
            default: why = unknownWhy
            }
            return .init(what: "\(stageName(stage, particle: "に"))失敗しました", why: why, actions: [.rerun], tone: .failure)
        }
    }

    public static func source(row: MeetingRow, item: QueueItemDTO?) -> Source? {
        if let item, item.state == JobState.waiting.rawValue, item.notBefore != nil {
            return .job(stage: item.stage, reason: item.message, waiting: true)
        }
        if row.state == .failed {
            if let item, item.state == JobState.failed.rawValue {
                return .job(stage: item.stage, reason: item.message)
            }
            return .job(stage: "", reason: nil)
        }
        if row.state == .transcriptOnly { return .summary(item?.summaryFailure) }
        return nil
    }

    /// The meeting's job for its failure band: a pending or failed one first, otherwise the done one, which carries
    /// the summary failure of a `transcript_only` row.
    public static func queueItem(for meetingID: String, in items: [QueueItemDTO]) -> QueueItemDTO? {
        let jobs = items.filter { $0.meetingID == meetingID }
        return jobs.first { $0.state != JobState.done.rawValue } ?? jobs.first { $0.summaryFailure != nil } ?? jobs.first
    }

    public static func actionTitle(_ a: Action) -> String {
        switch a {
        case .installGuide: "入れ方を見る"
        case .redetectClaudeAndRerun: "もう一度探して再実行"
        case .rerun: "再実行"
        case .openSystemSettings: "システム設定を開く"
        case .revealAudio: "録音を聞く"
        case .delete: "削除"
        case .changeOutputFolder: "保存先を変える"
        case .loginGuide: "ターミナルで claude を開く手順を見る"
        }
    }

    /// Stage name followed by a particle; the Latin "Automations" gets a space before it.
    private static func stageName(_ stage: String, particle: String) -> String {
        let name = stageName(stage)
        return name == "Automations" ? "\(name) \(particle)" : "\(name)\(particle)"
    }

    private static func stageName(_ stage: String) -> String {
        switch stage {
        case StageName.transcribe: "文字起こし"
        case StageName.summarize: "議事録の作成"
        case StageName.writeVault, StageName.updateIndex: "保存"
        case StageName.automations: "Automations"
        default: "処理"
        }
    }
}
