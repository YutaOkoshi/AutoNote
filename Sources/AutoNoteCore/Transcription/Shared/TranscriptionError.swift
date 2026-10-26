import Foundation

public enum TranscriptionError: Error, Equatable, Sendable {
    case modelMissing(String)
    case engineUnavailable(String)
    case localeUnsupported(Language)
    case invalidAudio(String)
    case whisperFailed(Int32)
    case noTracks
    case trackFailed(Track, String)
}
