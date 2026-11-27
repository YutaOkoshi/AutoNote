import Foundation

public actor SettingsStore {
    private let paths: AppPaths
    private let timeZone: TimeZone
    public private(set) var lastSetAside: URL?
    private let diagnostics: SettingsDiagnostics

    public init(paths: AppPaths, timeZone: TimeZone = .current, diagnostics: SettingsDiagnostics = .shared) {
        self.paths = paths
        self.timeZone = timeZone
        self.diagnostics = diagnostics
    }

    /// The file's settings, or the defaults when there is no file. A file that does not decode (not JSON, a wrong
    /// type, an unknown `default_language`) is moved aside as `settings.json.corrupt-<time>` and the defaults are
    /// returned; `diagnostics` gets where it failed and the new name. Values AutoNote ignored while decoding are
    /// reported there too (`Settings.init(from:)`).
    public func load() throws -> Settings {
        let file = paths.settingsFile
        guard FileManager.default.fileExists(atPath: file.path) else { return Settings() }
        let data = try Data(contentsOf: file)
        do {
            let decoder = AutoNoteJSON.decoder()
            decoder.userInfo[SettingsDiagnostics.userInfoKey] = diagnostics
            return try decoder.decode(Settings.self, from: data)
        } catch {
            let aside = file.deletingLastPathComponent()
                .appending(path: "settings.json.corrupt-\(timestamp(Date()))")
            try FileManager.default.moveItem(at: file, to: aside)
            lastSetAside = aside
            diagnostics.report(SettingsDiagnostics.fileSetAside(error, aside: aside.lastPathComponent))
            return Settings()
        }
    }

    public func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: paths.settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AutoNoteJSON.encoder().encode(settings).write(to: paths.settingsFile, options: .atomic)
    }

    @discardableResult
    public func update(_ body: @Sendable (inout Settings) -> Void) throws -> Settings {
        try change(body).new
    }

    /// `update` that also returns the settings before the change, for callers that react to the difference.
    /// Load, change and save happen in one actor turn, so no concurrent write is lost.
    @discardableResult
    public func change(_ body: @Sendable (inout Settings) -> Void) throws -> (old: Settings, new: Settings) {
        let old = try load()
        var s = old
        body(&s)
        try save(s)
        return (old, s)
    }

    private func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
