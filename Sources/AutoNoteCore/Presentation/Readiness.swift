import Foundation

/// Whether the three things a first meeting needs are in place: the output folder, the transcription model and Claude Code.
public struct Readiness: Sendable, Equatable {
    public enum Model: Sendable, Equatable {
        case installed(String)
        case downloading(String, fraction: Double)
        case failed(String, reason: String)
        case none
    }

    public struct OutputFolder: Sendable, Equatable {
        public var path: String
        public var available: Bool
        public init(path: String, available: Bool) {
            self.path = path
            self.available = available
        }
    }

    public struct Claude: Sendable, Equatable {
        public var path: String?
        public var found: Bool
        public init(path: String?, found: Bool) {
            self.path = path
            self.found = found
        }
    }

    public var outputFolder: OutputFolder
    public var model: Model
    public var claude: Claude

    public init(outputFolder: OutputFolder, model: Model, claude: Claude) {
        self.outputFolder = outputFolder
        self.model = model
        self.claude = claude
    }

    /// Complete means every part is ready; a model that is absent, downloading or failed is not.
    public var isComplete: Bool {
        guard outputFolder.available, claude.found else { return false }
        if case .installed = model { return true }
        return false
    }

    /// What the UI assumes before the first real check, so nothing flashes a warning.
    public static let assumedReady = Readiness(outputFolder: .init(path: "", available: true), model: .none,
                                               claude: .init(path: nil, found: true))
}

/// One line of the readiness card.
public struct ReadinessRow: Equatable, Sendable {
    public enum Item: Equatable, Sendable { case outputFolder, model, claude }
    public enum Action: Equatable, Sendable { case changeOutputFolder, retryModelDownload, installGuide, redetectClaude }

    public var item: Item
    public var title: String
    public var status: String
    public var ready: Bool
    public var band: String
    public var actions: [Action]

    public init(item: Item, title: String, status: String, ready: Bool, band: String, actions: [Action]) {
        self.item = item
        self.title = title
        self.status = status
        self.ready = ready
        self.band = band
        self.actions = actions
    }
}

public enum ReadinessPresentation {
    /// Always three rows: output folder, model, Claude.
    public static func rows(_ r: Readiness, home: String) -> [ReadinessRow] {
        [folderRow(r.outputFolder, home: home), modelRow(r.model), claudeRow(r.claude)]
    }

    /// The rows that are not ready, in the same order.
    public static func bands(_ r: Readiness, home: String) -> [ReadinessRow] {
        rows(r, home: home).filter { !$0.ready }
    }

    /// Replaces the home prefix with `~` only on a path-component boundary.
    public static func abbreviate(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func actionTitle(_ a: ReadinessRow.Action) -> String {
        switch a {
        case .changeOutputFolder: "保存先を変える"
        case .retryModelDownload: "もう一度"
        case .installGuide: "入れ方を見る"
        case .redetectClaude: "もう一度探す"
        }
    }

    private static func folderRow(_ f: Readiness.OutputFolder, home: String) -> ReadinessRow {
        let p = abbreviate(f.path, home: home)
        if f.available {
            return ReadinessRow(item: .outputFolder, title: "保存先", status: p, ready: true, band: "", actions: [])
        }
        if f.path.isEmpty {
            return ReadinessRow(item: .outputFolder, title: "保存先", status: "作れませんでした", ready: false,
                                band: "保存先を作れませんでした", actions: [.changeOutputFolder])
        }
        return ReadinessRow(item: .outputFolder, title: "保存先", status: "\(p) が見つかりません", ready: false,
                            band: "保存先 \(p) が見つかりません", actions: [.changeOutputFolder])
    }

    private static func modelRow(_ m: Readiness.Model) -> ReadinessRow {
        switch m {
        case .installed(let n):
            return ReadinessRow(item: .model, title: "文字起こしモデル（whisper \(n)）", status: "", ready: true, band: "", actions: [])
        case .downloading(let n, let fraction):
            let pct = min(100, max(0, Int((fraction * 100).rounded(.down))))
            return ReadinessRow(item: .model, title: "文字起こしモデル（whisper \(n)）", status: "ダウンロード中 \(pct) %", ready: false,
                                band: "文字起こしモデルをダウンロード中 \(pct) %（終わるまでは Apple 音声入力で文字起こしします）", actions: [])
        case .failed(let n, let reason):
            return ReadinessRow(item: .model, title: "文字起こしモデル（whisper \(n)）", status: "ダウンロードに失敗しました — \(reason)", ready: false,
                                band: "文字起こしモデルのダウンロードに失敗しました — \(reason)", actions: [.retryModelDownload])
        case .none:
            return ReadinessRow(item: .model, title: "文字起こしモデル（whisper）", status: "ありません（Apple 音声入力で文字起こしします）", ready: false,
                                band: "文字起こしモデルがありません（Apple 音声入力で文字起こしします）", actions: [])
        }
    }

    private static func claudeRow(_ c: Readiness.Claude) -> ReadinessRow {
        let title = "議事録の作成（Claude Code）"
        if c.found { return ReadinessRow(item: .claude, title: title, status: "", ready: true, band: "", actions: []) }
        return ReadinessRow(item: .claude, title: title, status: "見つかりません", ready: false,
                            band: "議事録の作成に Claude Code が要ります", actions: [.installGuide, .redetectClaude])
    }
}
