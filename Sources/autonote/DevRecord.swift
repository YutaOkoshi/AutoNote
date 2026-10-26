import AutoNoteCore
import Dispatch
import Foundation
import Synchronization

/// `autonote dev record --seconds <N> --out <dir> [--mic-uid <UID>] [--voice-processing] [--check-permission]`
/// Exit codes: 0 ok, 3 microphone permission not authorized, 1 anything else.
enum DevRecord {
    static let usage = "usage: autonote dev record --seconds <N> --out <dir> [--mic-uid <UID>] [--voice-processing] [--check-permission]"

    static func run(_ args: [String]) async -> Int32 {
        var seconds: Double?
        var out: URL?
        var micUID: String?
        var voiceProcessing = false
        var checkOnly = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--seconds":
                guard index + 1 < args.count, let n = Double(args[index + 1]), n > 0 else { return DevCommands.usageError(usage) }
                seconds = n; index += 2
            case "--out":
                guard index + 1 < args.count else { return DevCommands.usageError(usage) }
                out = URL(filePath: args[index + 1], directoryHint: .isDirectory); index += 2
            case "--mic-uid":
                guard index + 1 < args.count else { return DevCommands.usageError(usage) }
                micUID = args[index + 1]; index += 2
            case "--voice-processing":
                voiceProcessing = true; index += 1
            case "--check-permission":
                checkOnly = true; index += 1
            default:
                return DevCommands.usageError(usage)
            }
        }

        let permission = AVMicrophonePermission().status()
        let permissionLine = "{\"mic_permission\":\"\(permission.rawValue)\"}"
        if checkOnly {
            print(permissionLine)
            return 0
        }
        guard let seconds, let out else { return DevCommands.usageError(usage) }
        guard permission == .authorized else {
            print(permissionLine)
            return 3
        }

        do {
            var settings = Settings()
            settings.voiceProcessing = voiceProcessing
            let paths = AppPaths(root: out)
            let session = RecordingSession.live(paths: paths, settings: settings)

            let collector = EventCollector()
            let stream = await session.events()
            let listener = Task { for await event in stream { await collector.add(event) } }
            defer { listener.cancel() }

            // First SIGINT cuts the wait short; the stop path below still runs exactly once.
            signal(SIGINT, SIG_IGN)
            let waiter = Mutex<Task<Void, Never>?>(nil)
            let interrupted = Mutex(false)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            source.setEventHandler {
                interrupted.withLock { $0 = true }
                waiter.withLock { $0?.cancel() }
            }
            source.resume()
            defer { source.cancel() }

            _ = try await session.start(.init(language: .ja, microphoneUID: micUID))
            let sleeper = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(seconds)) }
            waiter.withLock { $0 = sleeper }
            if interrupted.withLock({ $0 }) { sleeper.cancel() }
            await sleeper.value
            let manifest = try await session.stop()
            let stats = await session.statistics()
            // Give the listener a moment to drain the final `.stopped` event.
            try? await Task.sleep(for: .milliseconds(100))

            let report = try RecordingReport.make(
                manifest: manifest, manifestURL: paths.manifestFile(manifest.id),
                meetingDirectory: paths.meetingDirectory(manifest.id),
                statistics: stats, events: await collector.events, micPermission: permission)
            print(try report.jsonLine())
            return 0
        } catch {
            DevCommands.printError("error: \(error)")
            return 1
        }
    }
}

private actor EventCollector {
    private(set) var events: [RecordingEvent] = []
    func add(_ event: RecordingEvent) { events.append(event) }
}
