import Foundation

/// Reads and writes `automations.json`. The caller passes `AppPaths.automationsFile`.
public struct AutomationsFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static let permissionWarning = "automations.json が自分以外から書き込める権限になっているため、Automations を無効にしました（chmod 600 で直せます）"

    private struct ParseFailure: Error { let message: String }

    public func load() -> AutomationsLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return AutomationsLoadResult() }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            return AutomationsLoadResult(warnings: ["automations.json を読めません（\(error.localizedDescription)）"])
        }
        let parsed: [(item: LoadedAutomation, decoded: Bool)]
        do { parsed = try Self.parse(data) } catch let f as ParseFailure {
            return AutomationsLoadResult(warnings: ["automations.json を読めません（\(f.message)）"])
        } catch {
            return AutomationsLoadResult(warnings: ["automations.json を読めません（\(error.localizedDescription)）"])
        }
        var items = parsed.map(\.item)
        if !hasSafePermissions() {
            for i in items.indices { items[i].isRunnable = false }
            return AutomationsLoadResult(items: items, warnings: [Self.permissionWarning], disabledByPermission: true)
        }
        return AutomationsLoadResult(items: items)
    }

    public func save(_ defs: [AutomationDefinition]) throws {
        let data = try AutoNoteJSON.encoder().encode(defs) + Data("\n".utf8)
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

    /// Validates `source` first (throws on broken JSON, file untouched), then replaces this file with its entries.
    public func importReplacing(from source: URL) throws -> AutomationsLoadResult {
        let parsed = try Self.parse(try Data(contentsOf: source))
        try save(parsed.filter(\.decoded).map(\.item.definition))
        return load()
    }

    private func hasSafePermissions() -> Bool {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return false }
        return st.st_mode & (S_IWGRP | S_IWOTH) == 0 && st.st_uid == getuid()
    }

    /// `decoded == false` means the entry had no usable name/trigger, so only a placeholder exists.
    private static func parse(_ data: Data) throws -> [(item: LoadedAutomation, decoded: Bool)] {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) } catch {
            throw ParseFailure(message: "JSON の形式が正しくありません")
        }
        guard let array = root as? [Any] else { throw ParseFailure(message: "最上位が配列ではありません") }
        var seen = Set<String>()
        var out: [(LoadedAutomation, Bool)] = []
        for (index, element) in array.enumerated() {
            let placeholder = AutomationDefinition(name: "", enabled: false, on: .minutesGenerated, command: "")
            guard let dict = element as? [String: Any] else {
                out.append((LoadedAutomation(definition: placeholder, isRunnable: false, problem: "\(index + 1) 件目がオブジェクトではありません"), false))
                continue
            }
            let name = dict["name"] as? String
            let rawTrigger = dict["on"] as? String
            var base = placeholder
            base.name = name ?? ""
            base.command = dict["command"] as? String ?? ""
            base.enabled = dict["enabled"] as? Bool ?? true
            if let t = dict["timeout_sec"] { base.timeoutSec = (t as? Int) ?? 0 } else { base.timeoutSec = AutomationDefinition.defaultTimeoutSec }
            guard let name, !name.isEmpty else {
                out.append((LoadedAutomation(definition: base, isRunnable: false, problem: "\(index + 1) 件目に name がありません"), false))
                continue
            }
            guard let rawTrigger else {
                out.append((LoadedAutomation(definition: base, isRunnable: false, problem: "きっかけ（on）がありません"), false))
                continue
            }
            guard let trigger = AutomationTrigger(rawValue: rawTrigger) else {
                out.append((LoadedAutomation(definition: base, isRunnable: false, problem: "きっかけ \(rawTrigger) は使えません"), false))
                continue
            }
            base.on = trigger
            var problem: String?
            if !seen.insert(name).inserted {
                problem = "同じ名前の Automation が先にあります"
            } else if base.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problem = "command が空です"
            } else if base.timeoutSec < 1 {
                problem = "timeout_sec は 1 以上にしてください"
            }
            out.append((LoadedAutomation(definition: base, isRunnable: problem == nil && base.enabled, problem: problem), true))
        }
        return out
    }
}
