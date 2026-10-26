import AutoNoteCore
import Foundation

/// `autonote dev devices [--watch]`
/// Default: every connected input device (candidate or not) as one JSON object per line, then exit 0.
/// `--watch`: the `DeviceMonitor` stream (candidates only) as `present` / `added` / `removed` lines until SIGINT, then exit 0.
enum DevDevices {
    static let usage = "usage: autonote dev devices [--watch]"

    static func run(_ args: [String]) async -> Int32 {
        switch args {
        case []: return list()
        case ["--watch"]: return await watch()
        default: return DevCommands.usageError(usage)
        }
    }

    private static func list() -> Int32 {
        let encoder = AutoNoteJSON.compactEncoder()
        for raw in CoreAudioHardware().snapshot() {
            guard let identity = DeviceIdentity(raw: raw) else { continue }
            emit(DeviceLine(identity: identity), encoder)
        }
        return 0
    }

    private static func watch() async -> Int32 {
        let encoder = AutoNoteJSON.compactEncoder()
        let monitor = DeviceMonitor(hardware: CoreAudioHardware(), power: WorkspaceSleepWakeObserver(),
                                    timer: TaskTimerScheduler())
        let events: AsyncStream<DeviceEvent>
        do {
            events = try await monitor.events()
        } catch {
            DevCommands.printError("error: device monitor: \(error)")
            return 1
        }

        // SIGINT ends the stream: ignore the default action, then stop the monitor from a dispatch source.
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { Task { await monitor.stop() } }
        source.resume()
        defer { source.cancel() }

        for await event in events {
            switch event {
            case .present(let d, _): emit(DeviceLine(identity: d, event: "present"), encoder)
            case .added(let d): emit(DeviceLine(identity: d, event: "added", at: Date()), encoder)
            case .removed(let d): emit(DeviceLine(identity: d, event: "removed", at: Date()), encoder)
            }
        }
        return 0
    }

    private static func emit(_ line: DeviceLine, _ encoder: JSONEncoder) {
        do {
            var data = try encoder.encode(line)
            data.append(UInt8(ascii: "\n"))
            FileHandle.standardOutput.write(data)
        } catch {
            DevCommands.printError("error: encode: \(error)")
        }
    }
}
