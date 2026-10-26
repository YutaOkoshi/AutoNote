import AutoNoteCore
import Foundation

/// One input device as a JSON line, shared by `dev auto-record` and `dev devices` (ruling Y15).
/// Keys: name, device_uid, model_uid (null when unknown), transport, input_channels, uid_kind, candidate,
/// and `event` / `at` only when set.
struct DeviceLine: Encodable {
    var name: String
    var deviceUID: String
    var modelUID: String?
    var transport: DeviceTransport
    var inputChannels: Int
    var uidKind: UIDKind
    var candidate: Bool
    var event: String?
    var at: Date?

    // `xxxUid` raw values: the snake-case strategy turns them into device_uid / model_uid (as in DeviceIdentity).
    private enum CodingKeys: String, CodingKey {
        case name, transport, inputChannels, uidKind, candidate, event, at
        case deviceUID = "deviceUid"
        case modelUID = "modelUid"
    }

    init(identity: DeviceIdentity, event: String? = nil, at: Date? = nil) {
        name = identity.name; deviceUID = identity.deviceUID; modelUID = identity.modelUID
        transport = identity.transport; inputChannels = identity.inputChannels; uidKind = identity.uidKind
        candidate = identity.isAutoRecordCandidate
        self.event = event; self.at = at
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(deviceUID, forKey: .deviceUID)
        try c.encode(modelUID, forKey: .modelUID)
        try c.encode(transport, forKey: .transport)
        try c.encode(inputChannels, forKey: .inputChannels)
        try c.encode(uidKind, forKey: .uidKind)
        try c.encode(candidate, forKey: .candidate)
        try c.encodeIfPresent(event, forKey: .event)
        try c.encodeIfPresent(at, forKey: .at)
    }

    /// The line with `"kind":"device"` added, for streams that mix several kinds of lines.
    struct Tagged: Encodable {
        var line: DeviceLine
        private enum CodingKeys: String, CodingKey { case kind }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("device", forKey: .kind)
            try line.encode(to: encoder)
        }
    }
}
