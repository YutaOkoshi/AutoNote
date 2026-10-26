import Foundation

/// Makes the two audio sources of a recording. `RecordingSession` asks for a fresh source at every start and attach.
public protocol AudioSourceFactory: Sendable {
    func makeSystemSource(clock: MeetingClock) -> any AudioSource
    func makeMicrophoneSource(deviceUID: String?, clock: MeetingClock) -> any AudioSource
    /// For `manifest.device`. nil uid = the default input.
    func inputDevice(uid: String?) -> DeviceRef?
}

/// Real hardware: a Core Audio process tap for system audio and `AVAudioEngine` for the microphone.
public struct LiveAudioSourceFactory: AudioSourceFactory {
    public let voiceProcessing: Bool
    public let tapLayout: AggregateLayout

    public init(voiceProcessing: Bool = false, tapLayout: AggregateLayout = .tapOnly) {
        self.voiceProcessing = voiceProcessing
        self.tapLayout = tapLayout
    }

    public func makeSystemSource(clock: MeetingClock) -> any AudioSource {
        ProcessTapSource(clock: clock, layout: tapLayout)
    }

    public func makeMicrophoneSource(deviceUID: String?, clock: MeetingClock) -> any AudioSource {
        MicrophoneSource(deviceUID: deviceUID, clock: clock, voiceProcessing: voiceProcessing)
    }

    public func inputDevice(uid: String?) -> DeviceRef? {
        CoreAudioDeviceLookup().deviceRef(forUID: uid)
    }
}
