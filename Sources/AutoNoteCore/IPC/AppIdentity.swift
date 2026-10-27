import Foundation

/// App-wide identity constants shared by the app, the CLI and the build/E2E scripts (`scripts/config.sh`).
public enum AppIdentity {
    public static let bundleID = "com.yutaokoshi.autonote"
    public static let dataDirectoryEnvironmentKey = "AUTONOTE_DATA_DIR"

    /// True when the data directory is overridden; same rule as `AppPaths.resolve` (present and non-empty).
    public static func isDataDirectoryOverridden(_ environment: [String: String]) -> Bool {
        if let dir = environment[dataDirectoryEnvironmentKey], !dir.isEmpty { return true }
        return false
    }

    /// The menu bar's 開発 menu (plan 02's TCC checks) is for development only: a launch with the data directory
    /// overridden (E2E, `scripts/tcc-check.sh`) or a debug build. End users never see it.
    public static func showsDevMenu(_ environment: [String: String], debugBuild: Bool) -> Bool {
        debugBuild || isDataDirectoryOverridden(environment)
    }
}
