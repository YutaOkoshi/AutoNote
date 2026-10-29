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
