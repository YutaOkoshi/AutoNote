import Foundation

/// The dictionary tab's editable copy of `dictionary.md` (plan 06 Task 15). `toFile` trims every cell and drops empty
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
}

/// Applied to every settings save. The countdown and grace seconds are the values `AutoRecordCoordinator` will use
/// (plan 03 owns the ranges; this plan has none of its own) and a negative retention becomes 0 (keep forever).
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
