import Foundation

/// Core Audio values for one device, with the transport already mapped. `audioObjectID` is never persisted.
public struct RawAudioDevice: Equatable, Sendable {
    public var audioObjectID: UInt32
    public var name: String?
    public var deviceUID: String?
    public var modelUID: String?
    public var transport: DeviceTransport
    public var inputChannels: Int
    public var outputChannels: Int

    public init(audioObjectID: UInt32, name: String?, deviceUID: String?, modelUID: String?,
                transport: DeviceTransport, inputChannels: Int, outputChannels: Int) {
        self.audioObjectID = audioObjectID; self.name = name; self.deviceUID = deviceUID; self.modelUID = modelUID
        self.transport = transport; self.inputChannels = inputChannels; self.outputChannels = outputChannels
    }
}

public enum DeviceTransport: String, Codable, Sendable {
    case builtin, bluetooth, usb, aggregate, virtual, unknown
}

/// Whether `deviceUID` carries something unique to the individual unit (serial number, MAC address).
public enum UIDKind: String, Codable, Sendable {
    case individual, portBased, fixed, unknown
}

public struct DeviceIdentity: Codable, Hashable, Sendable {
    public var name: String
    public var deviceUID: String
    public var modelUID: String?
    public var transport: DeviceTransport
    public var inputChannels: Int
    public var uidKind: UIDKind

    // Raw values are the camelCase form AutoNoteJSON's decoder produces from "device_uid" ("deviceUid", not "deviceUID"),
    // so the JSON keys are device_uid / model_uid / input_channels / uid_kind on both encode and decode.
    enum CodingKeys: String, CodingKey {
        case name, transport
        case deviceUID = "deviceUid"
        case modelUID = "modelUid"
        case inputChannels, uidKind
    }

    public init(name: String, deviceUID: String, modelUID: String?, transport: DeviceTransport,
                inputChannels: Int, uidKind: UIDKind) {
        self.name = name; self.deviceUID = deviceUID; self.modelUID = modelUID
        self.transport = transport; self.inputChannels = inputChannels; self.uidKind = uidKind
    }

    public init?(raw: RawAudioDevice) {
        guard raw.inputChannels > 0, let uid = raw.deviceUID else { return nil }
        self.init(name: raw.name ?? uid, deviceUID: uid, modelUID: raw.modelUID, transport: raw.transport,
                  inputChannels: raw.inputChannels, uidKind: Self.estimateUIDKind(transport: raw.transport, deviceUID: uid))
    }

    /// An input worth auto-recording for: not aggregate/virtual, and not AutoNote's own process-tap aggregate.
    public var isAutoRecordCandidate: Bool {
        inputChannels >= 1 && transport != .aggregate && transport != .virtual
            && !deviceUID.hasPrefix(ProcessTapSource.aggregateUIDPrefix)
    }

    public var deviceRef: DeviceRef { DeviceRef(name: name, uid: deviceUID, transport: transport.rawValue) }

    /// USB is an estimate (no hardware measured yet): `AppleUSBAudioEngine:<vendor>:<product>:<serial|locationID>:<n>`.
    static func estimateUIDKind(transport: DeviceTransport, deviceUID: String) -> UIDKind {
        switch transport {
        case .bluetooth: return .individual
        case .builtin: return .fixed
        case .usb:
            let parts = deviceUID.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 4, parts[0] == "AppleUSBAudioEngine" else { return .unknown }
            let field = parts[3]
            if field.isEmpty { return .portBased }
            let isLocationID = field.count == 8 && field.allSatisfy(\.isHexDigit) && field.hasSuffix("0000")
            return isLocationID ? .portBased : .individual
        case .aggregate, .virtual, .unknown: return .unknown
        }
    }
}
