import Foundation

/// The dictionary tab's editable copy of `dictionary.md`. `toFile` trims every cell and drops empty
/// rows; a replacement with only one side filled is an error that names its row.
public struct DictionaryDraft: Equatable, Sendable {
    public var terms: [String]
    public var replacements: [Replacement]
    public var fillers: [String]

    public init(_ f: DictionaryFile) {
        terms = f.terms
        replacements = f.replacements
        fillers = f.fillers
    }

    public func toFile() throws(AppCommandError) -> DictionaryFile {
        func cleaned(_ list: [String]) -> [String] {
            var out: [String] = []
            for item in list.map(Self.trim) where !item.isEmpty && !out.contains(item) { out.append(item) }
            return out
        }
        var pairs: [Replacement] = []
        for (index, r) in replacements.enumerated() {
            let from = Self.trim(r.from), to = Self.trim(r.to)
            if from.isEmpty && to.isEmpty { continue }
            guard !from.isEmpty, !to.isEmpty else { throw .invalid("置換の左右どちらかが空です（\(index + 1) 行目）") }
            guard !pairs.contains(where: { $0.from == from }) else {
                throw .invalid("同じ「誤」が 2 回あります（\(index + 1) 行目）")
            }
            pairs.append(Replacement(from: from, to: to))
        }
        return DictionaryFile(terms: cleaned(terms), replacements: pairs, fillers: cleaned(fillers))
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The Automations tab's edit sheet. Validation is `AutomationDefinition.problem(duplicateNames:)`, the same check
/// `AutomationsFile.load` applies (ruling X23).
public struct AutomationDraft: Equatable, Sendable {
    public var definition: AutomationDefinition

    public init(_ definition: AutomationDefinition) { self.definition = definition }

    /// `existing` are the other definitions (without the one being edited). Empty when `d` can be saved.
    public static func validate(_ d: AutomationDefinition, existing: [AutomationDefinition]) -> [String] {
        [d.problem(duplicateNames: Set(existing.map(\.name)))].compactMap { $0 }
    }

    public static let originalMissingMessage = "元の定義が見つかりません（ほかで変更されました）。閉じて開き直してください"

    /// Puts `edited` into `list`, a fresh read of `automations.json`. `original` is the definition as it was when the
    /// sheet opened (nil for a new one); it is found again by value in `list`, never by an index from an earlier
    /// read. Validation runs against the other entries of `list`. Throws `.notFound(originalMissingMessage)` when
    /// the original is gone (the sheet stays open), `.invalid` with the problems otherwise.
    public static func applying(_ edited: AutomationDefinition, replacing original: AutomationDefinition?,
                                in list: [AutomationDefinition]) throws(AppCommandError) -> [AutomationDefinition] {
        var out = list
        var others = list
        var index: Int?
        if let original {
            guard let i = list.firstIndex(of: original) else { throw .notFound(originalMissingMessage) }
            index = i
            others.remove(at: i)
        }
        let problems = validate(edited, existing: others)
        guard problems.isEmpty else { throw .invalid(problems.joined(separator: "\n")) }
        if let index { out[index] = edited } else { out.append(edited) }
        return out
    }
}

/// Applied to every settings save. The countdown and grace seconds are the values `AutoRecordCoordinator` will use
/// (the coordinator owns the ranges; the settings have none of their own) and a negative retention becomes 0 (keep forever).
public enum SettingsNormalizer {
    public static func normalized(_ s: Settings) -> Settings {
        var out = s
        let config = AutoRecordCoordinator.config(from: s)
        out.countdownSeconds = config.countdownSeconds
        out.disconnectGraceSeconds = config.graceSeconds
        if out.audioRetentionDays < 0 { out.audioRetentionDays = 0 }
        return out
    }
}

/// The 一般 tab's 「Claude の起動」: extra arguments as tokens and environment variables as name/value rows.
/// `validated()` trims the names, drops rows with an empty name and empty arguments, and rejects a name outside
/// `Settings.isValidEnvironmentName` or one given twice with an error that names its row. Values are kept as typed.
public struct ClaudeLaunchDraft: Equatable, Sendable {
    public struct EnvRow: Equatable, Sendable, Identifiable {
        public var id = UUID()
        public var name: String
        public var value: String

        public init(name: String, value: String) { self.name = name; self.value = value }
    }

    public var arguments: [String]
    public var environment: [EnvRow]

    public init(_ s: Settings) {
        arguments = s.claudeArgs
        environment = s.claudeEnv.sorted { $0.key < $1.key }.map { EnvRow(name: $0.key, value: $0.value) }
    }

    /// One typed entry is one argument, spaces included; nil when it is blank.
    public static func token(_ input: String) -> String? {
        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : input
    }

    public func validated() throws(AppCommandError) -> (arguments: [String], environment: [String: String]) {
        var env: [String: String] = [:]
        for (index, row) in environment.enumerated() {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { continue }
            guard Settings.isValidEnvironmentName(name) else {
                throw .invalid("環境変数の名前「\(name)」は使えません。英字・数字・_ だけで、数字で始めないでください（\(index + 1) 行目）")
            }
            guard env[name] == nil else { throw .invalid("同じ環境変数が 2 回あります（\(index + 1) 行目）") }
            env[name] = row.value
        }
        return (arguments.filter { !$0.isEmpty }, env)
    }
}
