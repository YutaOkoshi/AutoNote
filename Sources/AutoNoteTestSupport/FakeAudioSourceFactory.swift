import Foundation
import AutoNoteCore

/// Hands out scripted `FakeAudioSource`s and records the microphone UIDs asked for.
public final class FakeAudioSourceFactory: AudioSourceFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var _mic: FakeAudioSource
    private var _system: FakeAudioSource
    private var _nextMicrophone: FakeAudioSource?
    private var _microphoneUIDs: [String?] = []
    private var _devices: [String: DeviceRef]

    public static let defaultInput = DeviceRef(name: "Default", uid: "default", transport: "builtin")

    public init(mic: FakeAudioSource = FakeAudioSource(track: .mic), system: FakeAudioSource = FakeAudioSource(track: .system),
                devices: [String: DeviceRef] = [:]) {
        _mic = mic; _system = system; _devices = devices
    }

    /// The microphone source the next `makeMicrophoneSource` returns when `nextMicrophone` is nil (and the last one made).
    public var mic: FakeAudioSource {
        get { lock.withLock { _mic } }
        set { lock.withLock { _mic = newValue } }
    }
    public var system: FakeAudioSource {
        get { lock.withLock { _system } }
        set { lock.withLock { _system = newValue } }
    }
    /// Used once by the next `makeMicrophoneSource`, which then also becomes `mic`.
    public var nextMicrophone: FakeAudioSource? {
        get { lock.withLock { _nextMicrophone } }
        set { lock.withLock { _nextMicrophone = newValue } }
    }
    /// The `deviceUID` of every `makeMicrophoneSource` call, in order.
    public var microphoneUIDs: [String?] { lock.withLock { _microphoneUIDs } }
    /// Answers for `inputDevice(uid:)`; a nil uid answers `defaultInput`.
    public var devices: [String: DeviceRef] {
        get { lock.withLock { _devices } }
        set { lock.withLock { _devices = newValue } }
    }

    public func makeSystemSource(clock: MeetingClock) -> any AudioSource { system }

    public func makeMicrophoneSource(deviceUID: String?, clock: MeetingClock) -> any AudioSource {
        lock.withLock {
            _microphoneUIDs.append(deviceUID)
            if let next = _nextMicrophone {
                _nextMicrophone = nil
                _mic = next
            }
            return _mic
        }
    }

    public func inputDevice(uid: String?) -> DeviceRef? {
        guard let uid else { return Self.defaultInput }
        return devices[uid]
    }
}
