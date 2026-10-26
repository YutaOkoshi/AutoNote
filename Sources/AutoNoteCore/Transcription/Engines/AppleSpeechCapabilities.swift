import Foundation
import Speech

public protocol SpeechCapabilityProbing: Sendable {
    func dictationLocales() async -> [Locale]
    func speechTranscriberIsAvailable() async -> Bool
    func speechTranscriberLocales() async -> [Locale]
}

/// Asks the OS directly. Deliberately avoids `supportedLocale(equivalentTo:)`, which
/// answers even when nothing is usable (requirements doc 6.2).
public struct AppleSpeechCapabilities: SpeechCapabilityProbing {
    public init() {}

    public func dictationLocales() async -> [Locale] { await DictationTranscriber.supportedLocales }
    public func speechTranscriberIsAvailable() async -> Bool { SpeechTranscriber.isAvailable }
    public func speechTranscriberLocales() async -> [Locale] { await SpeechTranscriber.supportedLocales }
}
