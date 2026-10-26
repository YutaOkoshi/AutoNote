import Foundation

public enum PresenceReason: String, Sendable {
    case launch, wake
}

public enum DeviceEvent: Equatable, Sendable {
    case present(DeviceIdentity, PresenceReason)
    case added(DeviceIdentity)
    case removed(DeviceIdentity)
}

/// The post-wake window (spec §11.1): a device that was connected before sleep and reappears within the window
/// is not a connection event. Outside the window everything passes through unchanged.
public struct WakeSuppression: Sendable {
    public private(set) var inWindow = false
    private var presentBeforeSleep: Set<String> = []
    private var held: [DeviceIdentity] = []

    public init() {}

    /// Opens (or restarts) the window. Removals still held from an earlier window stay held.
    public mutating func didWake(present: Set<String>) {
        presentBeforeSleep = present.union(held.map(\.deviceUID))
        inWindow = true
    }

    public mutating func filter(added: [DeviceIdentity], removed: [DeviceIdentity])
        -> (added: [DeviceIdentity], removed: [DeviceIdentity]) {
        guard inWindow else { return (added, removed) }
        var passedRemoved: [DeviceIdentity] = []
        for device in removed {
            if presentBeforeSleep.contains(device.deviceUID) {
                if !held.contains(where: { $0.deviceUID == device.deviceUID }) { held.append(device) }
            } else {
                passedRemoved.append(device)
            }
        }
        var passedAdded: [DeviceIdentity] = []
        for device in added {
            if presentBeforeSleep.contains(device.deviceUID) {
                held.removeAll { $0.deviceUID == device.deviceUID }
            } else {
                passedAdded.append(device)
            }
        }
        return (passedAdded, passedRemoved)
    }

    /// Closes the window: held removals that did not come back become `.removed`, then every device in `current`
    /// that was connected before sleep becomes `.present(_, .wake)`.
    public mutating func endWindow(current: [DeviceIdentity]) -> [DeviceEvent] {
        guard inWindow else { return [] }
        let currentUIDs = Set(current.map(\.deviceUID))
        let events = held.filter { !currentUIDs.contains($0.deviceUID) }.map(DeviceEvent.removed)
            + current.filter { presentBeforeSleep.contains($0.deviceUID) }.map { DeviceEvent.present($0, .wake) }
        inWindow = false
        presentBeforeSleep = []
        held = []
        return events
    }
}
