import AutoNoteCore
import Foundation

/// `autonote dev auto-record --vault <dir> --data <dir> [--countdown N] [--grace N] [--lang ja|en|auto]`
/// Runs the real device monitor, registry and recorder behind `AutoRecordCoordinator`. Prints one JSON object per
/// line on stdout (`status`, `notice`, `withdraw`, `device`, `bookmark`, `error`) and reads one command per line on
/// stdin. EOF on stdin and SIGINT are `quit`. Exit codes: 0 after `quit`, 2 usage, 1 setup failure.
enum DevAutoRecord {
    static let usage = "usage: autonote dev auto-record --vault <dir> --data <dir> [--countdown N] [--grace N] [--lang ja|en|auto]"
        + "\n  stdin: yes|no|never <uid>, start <uid>, cancel, manual, pause, resume, bookmark [note], lang ja|en|auto, stop, quit"

    static func run(_ args: [String]) async -> Int32 {
        var vault: URL?
        var data: URL?
        var settings = Settings()
        var index = 0
        while index < args.count {
            guard index + 1 < args.count else { return DevCommands.usageError(usage) }
            let value = args[index + 1]
            switch args[index] {
            case "--vault": vault = URL(filePath: value, directoryHint: .isDirectory)
            case "--data": data = URL(filePath: value, directoryHint: .isDirectory)
            case "--countdown":
                guard let n = Int(value) else { return DevCommands.usageError(usage) }
                settings.countdownSeconds = n
            case "--grace":
                guard let n = Int(value) else { return DevCommands.usageError(usage) }
                settings.disconnectGraceSeconds = n
            case "--lang":
                guard let l = Language(rawValue: value) else { return DevCommands.usageError(usage) }
                settings.defaultLanguage = l
            default:
                return DevCommands.usageError(usage)
            }
            index += 2
        }
        guard let vault, let data else { return DevCommands.usageError(usage) }

        let paths = AppPaths(root: data)
        let store = PortableConfigStore(paths: paths, outputFolder: vault)
        do {
            try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
            try paths.createBaseDirectories()
            _ = try await store.sync()
        } catch {
            DevCommands.printError("error: \(error)")
            return 1
        }

        // stdin lines and SIGINT feed one command stream; SIGINT (default action ignored first) queues `quit`, so
        // Ctrl-C takes the same stop path as typing it. Installed before `run()` starts.
        let (commands, commandSink) = AsyncStream<String>.makeStream()
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigint.setEventHandler { commandSink.yield("quit") }
        sigint.resume()
        defer { sigint.cancel() }
        readStdinLines(into: commandSink)

        let out = LineWriter()
        let timer = TaskTimerScheduler()
        let monitor = DeviceMonitor(hardware: CoreAudioHardware(), power: WorkspaceSleepWakeObserver(), timer: timer)
        let registry = DeviceRegistry(storage: PortableDevicesStorage(store: store, paths: paths),
                                      mac: SystemMacIdentityProvider())
        let recorder = RecordingSessionControl(session: RecordingSession.live(paths: paths, settings: settings))
        let config = AutoRecordCoordinator.config(from: settings)
        let coordinator = AutoRecordCoordinator(
            monitor: monitor, registry: registry, recorder: recorder,
            notifier: ConsoleUserNotifier(out: out), timer: timer, config: { config })

        // The status line comes first: wait for the initial snapshot to be written before anything else runs.
        let snapshots = await coordinator.snapshots()
        let (firstWritten, firstSignal) = AsyncStream<Void>.makeStream()
        let statusTask = Task {
            for await snapshot in snapshots {
                await out.status(snapshot)
                firstSignal.yield()
                firstSignal.finish()
            }
        }
        for await _ in firstWritten { break }

        // A second subscriber next to the coordinator's own (Y5); `.present` arrives at subscription.
        let devices: AsyncStream<DeviceEvent>
        do {
            devices = try await monitor.events()
        } catch {
            DevCommands.printError("error: device monitor: \(error)")
            statusTask.cancel()
            return 1
        }
        let deviceTask = Task {
            for await event in devices {
                switch event {
                case .present(let d, _): await out.write(DeviceLine.Tagged(line: DeviceLine(identity: d, event: "present")))
                case .added(let d): await out.write(DeviceLine.Tagged(line: DeviceLine(identity: d, event: "added", at: Date())))
                case .removed(let d): await out.write(DeviceLine.Tagged(line: DeviceLine(identity: d, event: "removed", at: Date())))
                }
            }
        }

        let runTask = Task { await coordinator.run() }

        for await line in commands {
            if await execute(line, coordinator: coordinator, monitor: monitor, out: out) == .quit { break }
        }

        // quit, EOF or SIGINT: no state check outside the gate. Both calls go through the coordinator's gate and are
        // no-ops when they do not apply: a countdown is cancelled so its timer cannot start a session, and a session
        // in progress is stopped (Y13). Only then is `run()` cancelled.
        await coordinator.cancelCountdown()
        await coordinator.stop(reason: .appTerminating)
        runTask.cancel()
        await monitor.stop()
        await out.waitUntilWritten(await coordinator.current())
        deviceTask.cancel()
        statusTask.cancel()
        return 0
    }

    private enum Outcome { case `continue`, quit }

    private static func execute(_ line: String, coordinator: AutoRecordCoordinator, monitor: DeviceMonitor,
                                out: LineWriter) async -> Outcome {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let command = parts.first.map(String.init) else { return .continue }
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil

        /// The connected device's ref, or nil after printing an error line.
        func ref(_ uid: String) async -> DeviceRef? {
            if let device = await monitor.connected().first(where: { $0.deviceUID == uid }) { return device.deviceRef }
            await out.error("unknown device uid: \(uid)")
            return nil
        }

        switch (command, argument) {
        case ("yes", let uid?), ("no", let uid?), ("never", let uid?):
            let answer: RegisterAnswer = command == "yes" ? .yes : command == "no" ? .no : .never
            guard let ref = await ref(uid) else { return .continue }
            await coordinator.handle(.registerDevice(ref, answer: answer))
        case ("start", let uid?):
            guard let ref = await ref(uid) else { return .continue }
            await coordinator.handle(.startNow(ref))
        case ("cancel", nil):
            await coordinator.cancelCountdown()
        case ("manual", nil):
            do { try await coordinator.manualStart(language: nil) } catch { await out.error("manual start failed: \(error)") }
        case ("pause", nil):
            await coordinator.pause()
        case ("resume", nil):
            await coordinator.resume()
        case ("bookmark", let note):
            do {
                await out.write(BookmarkLine(bookmark: try await coordinator.bookmark(note: note)))
            } catch {
                await out.error("bookmark failed: \(error)")
            }
        case ("lang", let value?):
            guard let language = Language(rawValue: value) else {
                await out.error("unknown language: \(value)")
                return .continue
            }
            await coordinator.setLanguage(language)
        case ("stop", nil):
            await coordinator.stop(reason: .manual)
        case ("quit", nil):
            return .quit
        default:
            await out.error("unknown command: \(line)")
        }
        return .continue
    }

    /// Feeds stdin lines into `sink` from a detached thread and finishes it at EOF.
    private static func readStdinLines(into sink: AsyncStream<String>.Continuation) {
        Thread.detachNewThread {
            while let line = readLine() { sink.yield(line) }
            sink.finish()
        }
    }

    private struct BookmarkLine: Encodable {
        var kind = "bookmark"
        var bookmark: Bookmark
    }
}

/// Serializes every stdout line so lines from the status, device and notice paths never interleave.
actor LineWriter {
    private let encoder = AutoNoteJSON.compactEncoder()
    private var lastStatus: RecorderSnapshot?

    func write(_ value: some Encodable) {
        do {
            var data = try encoder.encode(value)
            data.append(UInt8(ascii: "\n"))
            FileHandle.standardOutput.write(data)
        } catch {
            DevCommands.printError("error: encode: \(error)")
        }
    }

    func status(_ snapshot: RecorderSnapshot) {
        lastStatus = snapshot
        write(StatusLine(snapshot: snapshot))
    }

    func error(_ message: String) { write(ErrorLine(message: message)) }

    /// Waits (up to about a second) until `snapshot` has been printed, so the final status reaches stdout before exit.
    func waitUntilWritten(_ snapshot: RecorderSnapshot) async {
        for _ in 0..<100 where lastStatus != snapshot {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// `{"kind":"status", ...RecorderSnapshot in snake_case}`.
    private struct StatusLine: Encodable {
        var snapshot: RecorderSnapshot
        private enum CodingKeys: String, CodingKey { case kind }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("status", forKey: .kind)
            try snapshot.encode(to: encoder)
        }
    }

    private struct ErrorLine: Encodable {
        var kind = "error"
        var message: String
    }
}

/// Prints notices as `{"kind":"notice","id":…,"body":…,"actions":[{"title":…,"action":…,"command":…}]}` and
/// withdrawals as `{"kind":"withdraw","id":…}`. `command` is the stdin line that presses the button.
struct ConsoleUserNotifier: UserNotifier {
    let out: LineWriter

    func post(_ notice: UserNotice) async {
        let actions = DeviceNoticeCopy.actions(for: notice).map { NoticeLine.Action(title: $0.title, action: $0.action) }
        await out.write(NoticeLine(id: notice.id, body: DeviceNoticeCopy.body(for: notice), actions: actions))
    }

    func withdraw(id: String) async {
        await out.write(WithdrawLine(id: id))
    }

    private struct NoticeLine: Encodable {
        var kind = "notice"
        var id: String
        var body: String?
        var actions: [Action]

        private enum CodingKeys: String, CodingKey { case kind, id, body, actions }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(body, forKey: .body)   // null for notices without device copy
            try c.encode(actions, forKey: .actions)
        }

        struct Action: Encodable {
            var title: String
            var action: String
            var command: String?

            init(title: String, action: UserNoticeAction) {
                self.title = title
                (self.action, command) = Self.describe(action)
            }

            /// The action's case name and, for the device actions, the stdin line that performs it.
            private static func describe(_ action: UserNoticeAction) -> (String, String?) {
                switch action {
                case .cancelCountdown: ("cancelCountdown", "cancel")
                case .startNow(let ref): ("startNow", "start \(ref.uid)")
                case .registerDevice(let ref, .yes): ("registerDevice", "yes \(ref.uid)")
                case .registerDevice(let ref, .no): ("registerDevice", "no \(ref.uid)")
                case .registerDevice(let ref, .never): ("registerDevice", "never \(ref.uid)")
                case .openMeeting: ("openMeeting", nil)
                case .retry: ("retry", nil)
                case .resolveOverwrite: ("resolveOverwrite", nil)
                case .transcribeTooShort: ("transcribeTooShort", nil)
                case .discardTooShort: ("discardTooShort", nil)
                case .recoverInterrupted: ("recoverInterrupted", nil)
                case .discardInterrupted: ("discardInterrupted", nil)
                case .openPrivacySettings: ("openPrivacySettings", nil)
                }
            }
        }
    }

    private struct WithdrawLine: Encodable {
        var kind = "withdraw"
        var id: String
    }
}
