import Foundation
import AutoNoteCore

public final class FakeAudioHardware: AudioHardwareQuerying, @unchecked Sendable {
    // All state guarded by `lock`.
    private let lock = NSLock()
    private var devices: [RawAudioDevice] = []
    private var handlers: [Int: @Sendable () -> Void] = [:]
    private var nextToken = 0
    private var cancelledTokens: Set<Int> = []

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

    /// True when at least one observation was issued and every issued observation has been cancelled.
    public var observationCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return nextToken > 0 && cancelledTokens.count == nextToken
    }

    public func observeDeviceList(_ onChange: @Sendable @escaping () -> Void) throws -> any HardwareObservation {
        lock.lock()
        let token = nextToken; nextToken += 1
        handlers[token] = onChange
        lock.unlock()
        return Observation(hardware: self, token: token)
    }

    fileprivate func remove(_ token: Int) {
        lock.lock(); handlers[token] = nil; cancelledTokens.insert(token); lock.unlock()
    }

    private struct Observation: HardwareObservation {
        let hardware: FakeAudioHardware
        let token: Int
        func cancel() { hardware.remove(token) }
    }
}
