import Foundation
import os
import Synchronization

/// Where AutoNote says that it did not use something written in `settings.json`: an unknown value replaced by a
/// default, entries it dropped, a whole file it could not read. Settings are read again and again (every live summary
/// tick, every settings screen), so each distinct line is written once per instance — once per run for `shared`.
/// Lines hold key names and the values of keys that are not secret; never `claude_env`'s names or values.
public final class SettingsDiagnostics: Sendable {
    public static let shared = SettingsDiagnostics()

    /// Writes to the unified log (subsystem `com.yutaokoshi.autonote`, category `Settings`) at `notice`, so the line
    /// can be read afterwards with `log show`.
    public static let systemLog: @Sendable (String) -> Void = { line in
        logger.notice("\(line, privacy: .public)")
    }

    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "Settings")

    /// A decoder's `userInfo` key for the instance `Settings.init(from:)` reports to (`shared` without it).
    public static let userInfoKey = CodingUserInfoKey(rawValue: "com.yutaokoshi.autonote.settings-diagnostics")!

    /// The longest value quoted in a line.
    static let valueLimit = 64

    private let sink: @Sendable (String) -> Void
    private let seen = Mutex<Set<String>>([])

    public init(sink: @escaping @Sendable (String) -> Void = SettingsDiagnostics.systemLog) {
        self.sink = sink
    }

    /// Writes `line` unless this instance already wrote the same one.
    public func report(_ line: String) {
        guard seen.withLock({ $0.insert(line).inserted }) else { return }
        sink(line)
    }

    /// `key` held `value`, which is not one of `known`; `fallback` says what is used instead.
    static func ignoredValue(key: String, value: String, known: [String], using fallback: String) -> String {
        "settings: ignored \(key) \"\(quoted(value))\" (known: \(known.joined(separator: ", "))); using \(fallback)"
    }

    /// `count` entries of `claude_env` had a name `Settings.isValidEnvironmentName` rejects. The names stay out of
    /// the log, like the rest of that key (`Settings.opaqueKeys`).
    static func droppedEnvironmentNames(_ count: Int) -> String {
        "settings: ignored \(count) claude_env name(s) (a name is [A-Za-z_][A-Za-z0-9_]*); those variables are not set"
    }

    /// `settings.json` did not decode and was moved to `aside`. Only where it failed is named, never the value there.
    static func fileSetAside(_ error: any Error, aside: String) -> String {
        "settings: settings.json could not be read (\(reason(error))); moved to \(aside), using the defaults"
    }

    /// One line, at most `valueLimit` characters.
    private static func quoted(_ value: String) -> String {
        let line = value.split(whereSeparator: \.isWhitespace).joined(separator: " ").replacing("\"", with: "'")
        return line.count > valueLimit ? String(line.prefix(valueLimit)) + "…" : line
    }

    private static func reason(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return "unreadable" }
        switch error {
        case .dataCorrupted(let c): return c.codingPath.isEmpty ? "not valid JSON" : "invalid value at \(path(c.codingPath))"
        case .typeMismatch(_, let c): return "wrong type at \(path(c.codingPath))"
        case .valueNotFound(_, let c): return "missing value at \(path(c.codingPath))"
        case .keyNotFound(let key, let c): return "missing key \(path(c.codingPath + [key]))"
        @unknown default: return "unreadable"
        }
    }

    /// The coding path as `settings.json` spells it (`shortcuts.toggle_recording`). Below `claude_env` the keys are
    /// the person's variable names, so the path stops there.
    private static func path(_ keys: [any CodingKey]) -> String {
        var names: [String] = []
        for key in keys {
            let name = key.intValue.map(String.init) ?? snakeCase(key.stringValue)
            names.append(name)
            if name == "claude_env" { break }
        }
        return names.isEmpty ? "the top level" : names.joined(separator: ".")
    }

    /// `defaultLanguage` → `default_language` (the decoder hands back the property's spelling).
    private static func snakeCase(_ s: String) -> String {
        s.reduce(into: "") { out, ch in
            if ch.isUppercase, !out.isEmpty { out += "_" }
            out += ch.lowercased()
        }
    }
}
