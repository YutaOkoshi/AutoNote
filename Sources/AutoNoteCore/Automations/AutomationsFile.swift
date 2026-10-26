import Foundation

/// Reads and writes `automations.json`. The caller passes `AppPaths.automationsFile`.
public struct AutomationsFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static let permissionWarning = "automations.json が自分以外から書き込める権限になっているため、Automations を無効にしました（chmod 600 で直せます）"

    private struct ParseFailure: Error { let message: String }

    public func load() -> AutomationsLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return AutomationsLoadResult() }
        let parsed: Parsed
        do { parsed = try Self.parse(try Data(contentsOf: url)) } catch let f as ParseFailure {
            return AutomationsLoadResult(warnings: ["automations.json を読めません（\(f.message)）"])
        } catch {
            return AutomationsLoadResult(warnings: ["automations.json を読めません（\(error.localizedDescription)）"])
        }
        var warnings = parsed.broken.map { "entries[\($0.index)]: \($0.reason)" }
        var items = parsed.items
        var disabled = false
        if !hasSafePermissions() {
            disabled = true
            warnings.insert(Self.permissionWarning, at: 0)
            for i in items.indices {
                items[i].isRunnable = false
                items[i].problem = Self.permissionWarning
            }
        }
        return AutomationsLoadResult(items: items, warnings: warnings, disabledByPermission: disabled)
    }

    /// Writes `defs` followed by the entries of the current file that cannot be decoded, verbatim, so a
    /// load-edit-save cycle never rewrites or drops a broken entry.
    public func save(_ defs: [AutomationDefinition]) throws {
        var array = try JSONSerialization.jsonObject(with: try AutoNoteJSON.encoder().encode(defs)) as? [Any] ?? []
        if FileManager.default.fileExists(atPath: url.path),
           let current = try? Self.parse(try Data(contentsOf: url)) {
            array.append(contentsOf: current.broken.map(\.raw))
        }
        let data = try JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            + Data("\n".utf8)
        try writeAtomically(data)
    }

    private func writeAtomically(_ data: Data) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            // createFile applies the umask; make the mode exact before it becomes visible.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if rename(tmp.path, url.path) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Writes the current file content (or an empty list when there is no file) to `to`.
    public func export(to dest: URL) throws {
        let data = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data("[]\n".utf8)
        try data.write(to: dest, options: .atomic)
    }

    /// Validates that `source` is a JSON array (throws otherwise, file untouched), then replaces this file with its bytes verbatim.
    public func importReplacing(from source: URL) throws -> AutomationsLoadResult {
        let data = try Data(contentsOf: source)
        _ = try Self.parse(data)
        try writeAtomically(data)
        return load()
    }

    private func hasSafePermissions() -> Bool {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return false }
        return st.st_mode & (S_IWGRP | S_IWOTH) == 0 && st.st_uid == getuid()
    }

    private struct Parsed {
        var items: [LoadedAutomation] = []
        var broken: [(index: Int, raw: Any, reason: String)] = []
    }

    private static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func parse(_ data: Data) throws -> Parsed {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) } catch {
            throw ParseFailure(message: "JSON の形式が正しくありません")
        }
        guard let array = root as? [Any] else { throw ParseFailure(message: "最上位が配列ではありません") }
        var out = Parsed()
        var seen = Set<String>()
        for (index, element) in array.enumerated() {
            func reject(_ reason: String) { out.broken.append((index, element, reason)) }
            guard let dict = element as? [String: Any] else { reject("オブジェクトではありません"); continue }
            guard let name = dict["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else { reject("name がありません"); continue }
            guard let command = dict["command"] as? String else { reject("command がありません"); continue }
            guard let rawTrigger = dict["on"] as? String else { reject("on がありません"); continue }
            guard let trigger = AutomationTrigger(rawValue: rawTrigger) else { reject("きっかけ \(rawTrigger) は使えません"); continue }
            var enabled = true
            if let e = dict["enabled"] {
                guard isBool(e), let b = e as? Bool else { reject("enabled は true か false にしてください"); continue }
                enabled = b
            }
            var timeout = AutomationDefinition.defaultTimeoutSec
            if let t = dict["timeout_sec"] {
                guard let n = t as? NSNumber, !isBool(t), n.doubleValue == Double(n.intValue) else { reject("timeout_sec は整数にしてください"); continue }
                timeout = n.intValue
            }
            let def = AutomationDefinition(name: name, enabled: enabled, on: trigger, command: command, timeoutSec: timeout)
            var problem: String?
            if !seen.insert(name).inserted {
                problem = "同じ名前の Automation が先にあります"
            } else if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problem = "command が空です"
            } else if timeout < 1 {
                problem = "timeout_sec は 1 以上にしてください"
            }
            out.items.append(LoadedAutomation(definition: def, isRunnable: problem == nil && enabled, problem: problem))
        }
        return out
    }
}
