import Foundation

/// What the updater is doing, for the settings, the menu and `autonote dev update --status`.
public enum UpdateStatus: Equatable, Sendable {
    /// Not checked in this launch yet.
    case idle
    case disabled
    case checking
    case upToDate
    case downloading(version: String, fraction: Double?)
    /// Downloaded and checked; swapped in when `UpdateInstallGate` allows (`waiting` says why not yet).
    case readyToInstall(version: String, waiting: String?)
    case installing(version: String)
    /// An automatic update cannot work from here (not writable, ad-hoc signed, not an .app).
    case manualRequired(String)
    case failed(String)

    /// The status line in the settings.
    public var text: String {
        switch self {
        case .idle: "まだ確認していません"
        case .disabled: "自動アップデートはオフです"
        case .checking: "確認しています…"
        case .upToDate: "最新の版です"
        case .downloading(let v, let f):
            if let f { "\(v) を取得しています（\(Int((f * 100).rounded())) %）" } else { "\(v) を取得しています…" }
        case .readyToInstall(let v, let waiting):
            if let waiting { "\(v) に更新できます。再起動を待っています（\(waiting)）" } else { "\(v) に更新できます" }
        case .installing(let v): "\(v) に入れ替えて再起動します…"
        case .manualRequired(let m): m
        case .failed(let m): m
        }
    }

    /// The `state` of the wire form.
    public var key: String {
        switch self {
        case .idle: "idle"
        case .disabled: "disabled"
        case .checking: "checking"
        case .upToDate: "up_to_date"
        case .downloading: "downloading"
        case .readyToInstall: "ready_to_install"
        case .installing: "installing"
        case .manualRequired: "manual_required"
        case .failed: "failed"
        }
    }

    public var version: String? {
        switch self {
        case .downloading(let v, _), .readyToInstall(let v, _), .installing(let v): v
        default: nil
        }
    }

    /// The menu's line for this status, or nil when the menu shows nothing.
    public var menuItem: MenuItem? {
        switch self {
        case .readyToInstall(let v, _): .installUpdate(version: v)
        case .manualRequired: .updateNeedsManual
        default: nil
        }
    }
}

/// `update.status` over the socket (`autonote dev update --status`).
public struct UpdateStatusDTO: Codable, Equatable, Sendable {
    public var state: String
    public var message: String
    public var version: String?
    public var currentVersion: String
    public var enabled: Bool
    public var lastCheckedAt: Date?
    public var waiting: String?
    public var lastInstall: UpdateInstallResult?

    public init(status: UpdateStatus, currentVersion: String, enabled: Bool, lastCheckedAt: Date?,
                lastInstall: UpdateInstallResult?) {
        state = status.key
        message = status.text
        version = status.version
        self.currentVersion = currentVersion
        self.enabled = enabled
        self.lastCheckedAt = lastCheckedAt
        if case .readyToInstall(_, let w) = status { waiting = w } else { waiting = nil }
        self.lastInstall = lastInstall
    }
}

/// The app's updater as the socket sees it.
public protocol UpdatePort: Sendable {
    func status() async -> UpdateStatusDTO
    /// 「今すぐ確認」: checks now (even when switched off or not due) and downloads what it finds.
    func checkNow() async -> UpdateStatusDTO
}

public struct NoUpdatePort: UpdatePort {
    public init() {}
    public func status() async -> UpdateStatusDTO {
        UpdateStatusDTO(status: .disabled, currentVersion: AutoNoteVersion.current, enabled: false, lastCheckedAt: nil,
                        lastInstall: nil)
    }
    public func checkNow() async -> UpdateStatusDTO { await status() }
}
