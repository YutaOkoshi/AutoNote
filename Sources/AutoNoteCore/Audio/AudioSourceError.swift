import Foundation
import CoreAudio

public enum MicrophonePermissionStatus: String, Sendable, Equatable {
    case authorized, denied, notDetermined, restricted
}

public enum AudioSourceError: Error, Equatable, Sendable {
    /// A Core Audio call returned a status other than `noErr`; `call` is the Core Audio function name.
    case coreAudio(call: String, status: OSStatus)
    case microphonePermission(MicrophonePermissionStatus)
    case deviceNotFound(uid: String)
    case alreadyStarted
    case unsupportedFormat
    /// A hardware call did not return within the caller's timeout; `call` is the Core Audio function name.
    case timedOut(call: String)
}
