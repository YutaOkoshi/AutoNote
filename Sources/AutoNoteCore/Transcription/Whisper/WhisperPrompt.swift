/// Builds whisper's initial prompt from dictionary hints, trimmed to whisper's token budget.
enum WhisperPrompt {
    static func make(hints: [String]) -> String? {
        let included = HintBudget.fit(hints, separator: "、").included
        return included.isEmpty ? nil : included.joined(separator: "、")
    }
}
