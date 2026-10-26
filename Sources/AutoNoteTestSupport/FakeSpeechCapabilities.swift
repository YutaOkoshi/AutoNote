import Foundation
import AutoNoteCore

/// Scripted `SpeechCapabilityProbing`; locales are given as BCP 47 strings.
public struct FakeSpeechCapabilities: SpeechCapabilityProbing {
    public let speechAvailable: Bool
    public let speechLocales: [Locale]
    public let dictationLocaleList: [Locale]

    public init(speechAvailable: Bool, speechLocales: [String], dictationLocales: [String]) {
        self.speechAvailable = speechAvailable
        self.speechLocales = speechLocales.map { Locale(identifier: $0) }
        self.dictationLocaleList = dictationLocales.map { Locale(identifier: $0) }
    }

    public func dictationLocales() async -> [Locale] { dictationLocaleList }
    public func speechTranscriberIsAvailable() async -> Bool { speechAvailable }
    public func speechTranscriberLocales() async -> [Locale] { speechLocales }
}
