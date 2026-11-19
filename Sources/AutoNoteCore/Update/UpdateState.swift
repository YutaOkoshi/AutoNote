import Foundation

/// What the updater keeps between launches, in `<data>/updates/state.json`.
public struct UpdateState: Codable, Equatable, Sendable {
    /// The last check that reached the feed (successful or not, but not one skipped while switched off).
    public var lastCheckedAt: Date?
    /// A version whose swap failed and was rolled back: not installed again automatically (「今すぐ確認」 clears it).
    public var failedVersion: String?
    /// Checks in a row that could not reach GitHub, and when the next one may run (`UpdateSchedule.retryDelay`).
    /// Both clear on the next check that connects.
    public var networkFailures: Int
    public var retryAt: Date?

    public init(lastCheckedAt: Date? = nil, failedVersion: String? = nil, networkFailures: Int = 0, retryAt: Date? = nil) {
        self.lastCheckedAt = lastCheckedAt
        self.failedVersion = failedVersion
        self.networkFailures = networkFailures
        self.retryAt = retryAt
    }

    // Camel case here: `AutoNoteJSON` converts to and from snake case (`last_checked_at`).
    enum CodingKeys: String, CodingKey { case lastCheckedAt, failedVersion, networkFailures, retryAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastCheckedAt = try c.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        failedVersion = try c.decodeIfPresent(String.self, forKey: .failedVersion)
        networkFailures = try c.decodeIfPresent(Int.self, forKey: .networkFailures) ?? 0
        retryAt = try c.decodeIfPresent(Date.self, forKey: .retryAt)
    }
}

/// What the install helper wrote when it finished (`last-install.json`), read once by the next launch.
public struct UpdateInstallResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// The new app is in place and running.
        case installed
        /// Something failed; the old app was put back and started again.
        case restored
        /// The app did not quit in time; nothing was touched.
        case skipped
    }

    public var from: String
    public var to: String
    public var result: Outcome
    /// Short step name (`move-aside`, `staged`, `move-new`, `verify`, `swap`, `launch`, `timeout`); empty on success.
    public var reason: String

    public init(from: String, to: String, result: Outcome, reason: String) {
        self.from = from
        self.to = to
        self.result = result
        self.reason = reason
    }

    /// The reason as the settings show it.
    public var reasonText: String {
        switch reason {
        case "move-aside": "今のアプリを退避できませんでした"
        case "staged": "取得したアプリが置き場所に無いか、別の場所へのリンクに替わっていました"
        case "move-new": "新しいアプリを置けませんでした"
        case "swap": "アプリを入れ替えられませんでした"
        case "verify": "置いたアプリの署名を確かめられませんでした"
        case "launch": "新しいアプリを起動できませんでした"
        case "timeout": "アプリが時間内に終了しませんでした"
        default: reason
        }
    }
}

public actor UpdateStateStore {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public var stateFile: URL { directory.appending(path: "state.json") }
    public var resultFile: URL { directory.appending(path: "last-install.json") }
    public var logFile: URL { directory.appending(path: "install.log") }

    public func load() -> UpdateState {
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? AutoNoteJSON.decoder().decode(UpdateState.self, from: data) else { return UpdateState() }
        return state
    }

    public func save(_ state: UpdateState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AutoNoteJSON.encoder().encode(state).write(to: stateFile, options: .atomic)
    }

    @discardableResult
    public func update(_ body: @Sendable (inout UpdateState) -> Void) throws -> UpdateState {
        var s = load()
        body(&s)
        try save(s)
        return s
    }

    /// The helper's result, removed once read so it is reported a single time. Nil when there is none or it is
    /// unreadable.
    public func takeInstallResult() -> UpdateInstallResult? {
        defer { try? FileManager.default.removeItem(at: resultFile) }
        guard let data = try? Data(contentsOf: resultFile) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(UpdateInstallResult.self, from: data)
    }
}
