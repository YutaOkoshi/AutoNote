import Foundation

/// Builds the summarizer from the current settings on every run, so a changed `claude` path or model
/// takes effect without restarting the app.
public enum SummarizerFactory {
    public static func make(settings: Settings, paths: AppPaths) async throws -> any Summarizer {
        switch settings.summarizerKind {
        case .claudeCode:
            let located: String?
            if let configured = settings.claudePath { located = configured } else { located = await ClaudeLocator.locate() }
            guard let claudePath = located else { throw SummarizerError.claudeNotFound(path: "") }
            return ClaudeCodeSummarizer(claudePath: claudePath, model: settings.claudeModel,
                                        workingDirectory: paths.claudeWorkingDirectory)
        }
    }
}
