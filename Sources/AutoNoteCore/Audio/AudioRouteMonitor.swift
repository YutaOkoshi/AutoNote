import Foundation
import CoreAudio
import os

/// One-line description of the default input and output devices for diagnostics: transport, nominal sample rate,
/// channel count and whether some process runs IO on it. Never a device name, UID or Bluetooth address.
public enum AudioRoute {
    static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "AudioRoute")

    /// e.g. `in=bluetooth/16000Hz/1ch/running out=bluetooth/44100Hz/2ch/idle`.
    public static func describeDefaults() -> String {
        "in=\(describe(defaultDevice(kAudioHardwarePropertyDefaultInputDevice), scope: kAudioObjectPropertyScopeInput)) "
            + "out=\(describe(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice), scope: kAudioObjectPropertyScopeOutput))"
    }

    static func describe(_ id: AudioObjectID?, scope: AudioObjectPropertyScope) -> String {
        guard let id else { return "none" }
        let transport = CoreAudioHardware.transport(coreAudio: CoreAudioHardware.uint32Prop(id, kAudioDevicePropertyTransportType)).rawValue
        let rate = nominalSampleRate(id).map { String(Int($0.rounded())) + "Hz" } ?? "?Hz"
        let channels = CoreAudioHardware.channelCount(id, scope)
        let running = CoreAudioHardware.uint32Prop(id, kAudioDevicePropertyDeviceIsRunningSomewhere).map { $0 != 0 ? "running" : "idle" } ?? "?"
        return "\(transport)/\(rate)/\(channels)ch/\(running)"
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func nominalSampleRate(_ id: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr ? rate : nil
    }
}

/// Watches the route while a meeting records and logs one line per change. Read-only: it never changes a device.
public protocol AudioRouteMonitoring: Sendable {
    /// Logs the route at the start of `label` (a meeting ID) and begins listening.
    func start(label: String)
    /// Logs the route once more and stops listening. Idempotent.
    func stop()
}

/// Listens on the system object for default input / output changes and on the current default devices for nominal
/// sample rate changes (re-attached when a default changes). All listener blocks run on one serial queue.
public final class CoreAudioRouteMonitor: AudioRouteMonitoring, @unchecked Sendable {   // state touched only on `queue`
    private struct Listener {
        var object: AudioObjectID
        var address: AudioObjectPropertyAddress
        var block: AudioObjectPropertyListenerBlock
    }

    private let queue = DispatchQueue(label: "com.yutaokoshi.autonote.audioroute")
    private var label = ""
    private var systemListeners: [Listener] = []
    private var rateListeners: [Listener] = []
    private var active = false

    public init() {}

    deinit {
        for l in systemListeners + rateListeners { Self.remove(l, queue) }
    }

    public func start(label: String) {
        queue.sync {
            guard !active else { return }
            active = true
            self.label = label
            AudioRoute.logger.notice("\(label, privacy: .public): route at recording start \(AudioRoute.describeDefaults(), privacy: .public)")
            for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
                let which = selector == kAudioHardwarePropertyDefaultInputDevice ? "input" : "output"
                if let l = add(AudioObjectID(kAudioObjectSystemObject), selector, { [weak self] in
                    self?.defaultChanged(which)
                }) { systemListeners.append(l) }
            }
            attachRateListeners()
        }
    }

    public func stop() {
        queue.sync {
            guard active else { return }
            active = false
            for l in systemListeners + rateListeners { Self.remove(l, queue) }
            systemListeners = []; rateListeners = []
            AudioRoute.logger.notice("\(self.label, privacy: .public): route at recording end \(AudioRoute.describeDefaults(), privacy: .public)")
        }
    }

    // MARK: - On `queue`

    private func defaultChanged(_ which: String) {
        guard active else { return }
        AudioRoute.logger.notice("\(self.label, privacy: .public): default \(which, privacy: .public) changed \(AudioRoute.describeDefaults(), privacy: .public)")
        attachRateListeners()
    }

    private func rateChanged(_ which: String) {
        guard active else { return }
        AudioRoute.logger.notice("\(self.label, privacy: .public): \(which, privacy: .public) nominal sample rate changed \(AudioRoute.describeDefaults(), privacy: .public)")
    }

    private func attachRateListeners() {
        for l in rateListeners { Self.remove(l, queue) }
        rateListeners = []
        let pairs: [(String, AudioObjectPropertySelector)] = [("input", kAudioHardwarePropertyDefaultInputDevice), ("output", kAudioHardwarePropertyDefaultOutputDevice)]
        var seen = Set<AudioObjectID>()
        for (which, selector) in pairs {
            guard let device = AudioRoute.defaultDevice(selector), seen.insert(device).inserted else { continue }
            if let l = add(device, kAudioDevicePropertyNominalSampleRate, { [weak self] in self?.rateChanged(which) }) {
                rateListeners.append(l)
            }
        }
    }

    private func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ body: @escaping () -> Void) -> Listener? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in body() }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        guard status == noErr else {
            AudioRoute.logger.error("route listener not added (status \(status, privacy: .public))")
            return nil
        }
        return Listener(object: object, address: address, block: block)
    }

    private static func remove(_ l: Listener, _ queue: DispatchQueue) {
        var address = l.address
        _ = AudioObjectRemovePropertyListenerBlock(l.object, &address, queue, l.block)   // gone already = nothing to do
    }
}
