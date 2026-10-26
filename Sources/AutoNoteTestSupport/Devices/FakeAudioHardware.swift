import Foundation
import AutoNoteCore

public final class FakeAudioHardware: AudioHardwareQuerying, @unchecked Sendable {
    // All state guarded by `lock`.
    private let lock = NSLock()
    private var devices: [RawAudioDevice] = []
    private var handlers: [Int: @Sendable () -> Void] = [:]
    private var nextToken = 0
    private var cancelledFlag = false

    public init() {}

    public func setDevices(_ devices: [RawAudioDevice]) {
        lock.lock(); self.devices = devices; lock.unlock()
    }

    public func snapshot() -> [RawAudioDevice] {
        lock.lock(); defer { lock.unlock() }
        return devices
    }

    /// Calls every live observer's handler, as Core Audio would after the device list changed.
    public func fireChange() {
        lock.lock(); let live = Array(handlers.values); lock.unlock()
        live.forEach { $0() }
    }

    public var observationCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledFlag
    }

    public func observeDeviceList(_ onChange: @Sendable @escaping () -> Void) throws -> any HardwareObservation {
        lock.lock()
        let token = nextToken; nextToken += 1
        handlers[token] = onChange
        cancelledFlag = false
        lock.unlock()
        return Observation(hardware: self, token: token)
    }

    fileprivate func remove(_ token: Int) {
        lock.lock(); handlers[token] = nil; cancelledFlag = true; lock.unlock()
    }

    private struct Observation: HardwareObservation {
        let hardware: FakeAudioHardware
        let token: Int
        func cancel() { hardware.remove(token) }
    }
}
