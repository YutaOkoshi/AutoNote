import CryptoKit
import Foundation

/// Moves `prompt.md` to the current default instructions when schema v2 changed them.
/// - A file that is exactly an old default (SHA-256 match, surrounding whitespace ignored) is replaced by
///   `DefaultPrompt.instructions`: the user never edited it.
/// - An edited file is left alone; the 議事録 settings tab offers 「差分を見る / 既定に戻す」 instead (`needsReview`).
public enum PromptMigration {
    /// SHA-256 of every default `instructions` shipped before the current one (0.2.1 and earlier: one text).
    /// `PromptMigrationTests.legacyHashMatchesLegacyText` pins it to `DefaultPrompt.legacyInstructionsV1`.
    public static let legacyDefaultSHA256s: Set<String> = [
        "4d4869084adf262a8299e1dc3097d16fe6e3a9ce66012ae64e80034254c2039c",
    ]

    public enum State: Equatable, Sendable {
        /// No file, or only whitespace: the summarizer uses the built-in default.
        case empty
        case currentDefault
        case legacyDefault
        case customized
    }

    public static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func state(of text: String?) -> State {
        guard let text else { return .empty }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed == DefaultPrompt.instructions.trimmingCharacters(in: .whitespacesAndNewlines) { return .currentDefault }
        if legacyDefaultSHA256s.contains(sha256(text)) || legacyDefaultSHA256s.contains(sha256(trimmed)) { return .legacyDefault }
        return .customized
    }

    /// Key names only the v2 instructions talk about. An edited prompt that already mentions one was written for v2.
    static let v2Markers = ["attendees", "key_points", "risks", "questions", "deadlines"]

    /// The settings band: an edited prompt written before v2 (it names none of the v2 keys).
    public static func needsReview(_ text: String?) -> Bool {
        guard state(of: text) == .customized, let text else { return false }
        return !v2Markers.contains { text.contains($0) }
    }

    /// Reads `prompt.md`; an untouched old default is rewritten with the current default first.
    /// Returns the file's content after the migration (nil when there is no file).
    public static func migrate(_ store: PortableConfigStore) async throws -> String? {
        guard let data = try await store.read(.prompt) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard state(of: text) == .legacyDefault else { return text }
        try await store.write(.prompt, Data(DefaultPrompt.instructions.utf8))
        return DefaultPrompt.instructions
    }

    /// What `prompt.md` gives the summarizer: the migrated file, or the built-in default when it is missing or empty.
    public static func effectiveInstructions(_ store: PortableConfigStore) async throws -> String {
        guard let text = try await migrate(store),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return DefaultPrompt.instructions }
        return text
    }
}
