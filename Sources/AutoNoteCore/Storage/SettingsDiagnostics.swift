import Foundation
import os
import Synchronization

/// Where AutoNote says that it did not use something written in `settings.json`: an unknown value replaced by a
/// default, an engine that cannot run here, entries it dropped, a whole file it could not read. Settings are read
/// again and again (every live summary tick, every settings screen), so the same line is written at most once per
/// `repeatInterval`. The app stays up for days and the settings are read again whenever a recording starts, so a
/// value that is still ignored shows up again then, inside the hour `log show --last 1h` looks at.
/// Lines hold key names and the values of keys that are not secret; never `claude_env`'s names or values.
public final class SettingsDiagnostics: Sendable {
    public static let shared = SettingsDiagnostics()

    /// How long the same line stays quiet after it was written.
    public static let repeatInterval: TimeInterval = 30 * 60

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
    private let now: @Sendable () -> Date
    /// When each line was last written (lines older than `repeatInterval` are forgotten).
    private let written = Mutex<[String: Date]>([:])

    public init(sink: @escaping @Sendable (String) -> Void = SettingsDiagnostics.systemLog,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.sink = sink
        self.now = now
    }

    /// Writes `line` unless this instance wrote the same one less than `repeatInterval` ago.
    public func report(_ line: String) {
        let time = now()
        let write = written.withLock { written -> Bool in
            // A clock set back makes the last write look like the future: treat that as long ago.
            written = written.filter { (0..<Self.repeatInterval).contains(time.timeIntervalSince($0.value)) }
            guard written[line] == nil else { return false }
            written[line] = time
            return true
        }
        if write { sink(line) }
    }

    /// `key` held `value`, which is not one of `known`; `fallback` says what is used instead.
    static func ignoredValue(key: String, value: String, known: [String], using fallback: String) -> String {
        "settings: ignored \(key) \"\(quoted(value))\" (known: \(known.joined(separator: ", "))); using \(fallback)"
    }

    /// The engine the settings ask for under `key` is a known one that cannot run (`why`), so `fallback` runs.
    /// `model` is the whisper model the choice came with (written in the file, or the role's default).
    static func unusableEngine(key: String, kind: String, model: String?, why: String, using fallback: String) -> String {
        let choice = "\"\(quoted(kind))\"" + (model.map { " with model \"\(quoted($0))\"" } ?? "")
        return "settings: ignored \(key) \(choice) (\(why)); using \(fallback)"
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
