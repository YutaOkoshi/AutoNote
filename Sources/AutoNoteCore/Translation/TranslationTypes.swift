import Foundation

/// A language the translation feature reads or writes. The model knows 53 languages; the feature uses two.
public enum TranslationLanguage: String, Codable, Hashable, Sendable, CaseIterable {
    case ja, en

    /// The other one (the automatic direction: Japanese ↔ English).
    public var opposite: TranslationLanguage { self == .ja ? .en : .ja }

    public var displayName: String { self == .ja ? "日本語" : "英語" }
}

/// What to translate into (setting `translation_target`). `auto` flips each utterance: Japanese → English,
/// anything else → Japanese.
public enum TranslationTarget: String, Codable, Hashable, Sendable, CaseIterable {
    case auto, ja, en

    public var displayName: String {
        switch self {
        case .auto: "自動（日本語 ↔ 英語）"
        case .ja: "日本語"
        case .en: "英語"
        }
    }
}

/// When to translate (setting `translation_mode`). `duringRecording` also translates after the recording.
public enum TranslationMode: String, Codable, Hashable, Sendable, CaseIterable {
    case off
    case afterRecording = "after_recording"
    case duringRecording = "during_recording"

    public var displayName: String {
        switch self {
        case .off: "オフ"
        case .afterRecording: "録音後に訳す"
        case .duringRecording: "録音中も訳す（録音後も訳す）"
        }
    }

    /// Whether the final transcript is translated on its own after a recording.
    public var translatesAfterRecording: Bool { self != .off }
}

/// What can go wrong in the translation feature. None of these ever changes a meeting's state.
public enum TranslationError: Error, Equatable, Sendable {
    /// No on-device runtime in this build (the llama.cpp `TextCompleting` is not wired yet).
    case runtimeUnavailable
    /// The license has not been accepted, so no model may be downloaded or used.
    case licenseNotAccepted
    /// The model file is not downloaded.
    case modelNotInstalled(String)
    /// The meeting has no final transcript to translate.
    case noTranscript
    /// The runtime failed (load or generation); the message is for the log and the band.
    case failed(String)

    /// What the meeting screen shows.
    public var message: String {
        switch self {
        case .runtimeUnavailable: "このビルドには端末内の翻訳エンジンが入っていません"
        case .licenseNotAccepted: "翻訳モデルのライセンスに同意していません（設定 → 翻訳）"
        case .modelNotInstalled(let name): "翻訳モデル \(name) をダウンロードしていません（設定 → 翻訳）"
        case .noTranscript: "確定版の文字起こしがありません"
        case .failed(let m): m
        }
    }
}
