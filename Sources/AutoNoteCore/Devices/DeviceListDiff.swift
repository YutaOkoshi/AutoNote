import Foundation

/// Diffs successive input-device lists, keyed by `deviceUID` (audioObjectID changes on reconnect and is not identity).
/// Only auto-record candidates are tracked, so an output appearing first, aggregates and virtual devices are no events.
public struct DeviceListDiff: Sendable {
    public private(set) var known: [String: DeviceIdentity] = [:]
    private var order: [String] = []

    public init() {}

    /// Returns removed (in the previous list's order) then added (in `current` order).
    /// `removed` carries the cached identity because a vanished device can no longer be queried.
    public mutating func update(with current: [RawAudioDevice]) -> (added: [DeviceIdentity], removed: [DeviceIdentity]) {
        var currentOrder: [String] = []
        var currentByUID: [String: DeviceIdentity] = [:]
        for raw in current {
            guard let identity = DeviceIdentity(raw: raw), identity.isAutoRecordCandidate,
                  currentByUID[identity.deviceUID] == nil else { continue }
            currentOrder.append(identity.deviceUID)
            currentByUID[identity.deviceUID] = identity
        }
        let removed = order.compactMap { currentByUID[$0] == nil ? known[$0] : nil }
        let added = currentOrder.compactMap { known[$0] == nil ? currentByUID[$0] : nil }
        known = currentByUID
        order = currentOrder
        return (added, removed)
    }
}
