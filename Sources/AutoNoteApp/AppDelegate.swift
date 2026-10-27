import AVFoundation
import AppKit
import AutoNoteCore
import Foundation
import os

private let logger = Logger(subsystem: AppIdentity.bundleID, category: "AppDelegate")

/// The launch order of plan 06 Task 13 (`applicationDidFinishLaunching` items 1–7) and the terminate hooks.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Nil until `AppEnvironment.make` finishes (or when it failed).
    private(set) var env: AppEnvironment?

    /// What the scenes read (the environment, window opening).
    let shell = AppShell()
    private var hotKeys: HotKeyCenter?

    /// Why the app is quitting: `.powerOff` for SIGTERM and `NSWorkspace.willPowerOffNotification`. A power-off
    /// that was cancelled puts it back to `.user` (`resetQuitReason`).
    private(set) var quitReason: QuitReason = .user

    private var sigtermSource: (any DispatchSourceSignal)?
    private var observers: [any NSObjectProtocol] = []
    private var tasks: [Task<Void, Never>] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationSignals()
        // Before any `await`: the notification center's delegate must exist when a cold-launching tap arrives (M9).
        let notifier = SystemUserNotifier()
        Task { await launch(notifier: notifier) }
    }

    private func launch(notifier: SystemUserNotifier) async {
        let environment = ProcessInfo.processInfo.environment

        // A second instance quits before building anything (the services would sync the output folder too).
        let socketFile = AppPaths.resolve(environment: environment).socketFile
        if await Self.isAnotherInstanceRunning(socketFile: socketFile) {
            logger.error("another AutoNote is already running; quitting")
            NSLog("AutoNote: another instance is already running (%@); quitting", socketFile.path)
            NSApp.terminate(nil)
            return
        }

        // 0. First-run defaults: an unset output folder becomes `~/Documents/AutoNote` (`<data>/vault` under
        //    `AUTONOTE_DATA_DIR`) before the services read it. A quick file-system step; a failure does not stop the launch.
        //    Always at launch: on the very first run the macOS Documents-folder prompt may come now.
        await Self.applyFirstRunDefaults(environment: environment)

        // 1. Build the services and start the socket (`.alreadyRunning` is the second line of defence).
        let env: AppEnvironment
        do {
            env = try await AppEnvironment.make(environment: environment, notifier: notifier)
        } catch {
            logger.error("launch failed: \(String(describing: error), privacy: .public)")
            NSLog("AutoNote: launch failed: %@", String(describing: error))
            showLaunchFailure(error)
            NSApp.terminate(nil)
            return
        }
        do {
            try await env.server.start()
        } catch .alreadyRunning {
            logger.error("another AutoNote is already running; quitting")
            NSLog("AutoNote: another instance is already running (%@); quitting", env.paths.socketFile.path)
            NSApp.terminate(nil)
            return
        } catch {
            logger.error("socket server failed to start: \(String(describing: error), privacy: .public)")
            NSLog("AutoNote: socket server failed to start: %@", String(describing: error))
        }
        self.env = env
        shell.env = env
        let shell = shell
        env.openWindow = { shell.open(AppShell.mainWindowID) }
        env.isMainWindowOpen = { [shell] in shell.isMainWindowOpen }

        // 2. Subscriptions start right away: the socket already accepts commands (ruling X48).
        let wiring = env.wiring, queue = env.queue, model = env.model
        tasks.append(Task { await wiring.run() })
        // After the saved jobs are loaded, a `.recorded` meeting with no job (the app quit between a stop and its
        // `route`) is enqueued again (I2).
        let manifests = env.manifests, queuePort = env.ports.queue
        tasks.append(Task {
            await queue.queue.start()
            await wiring.sweepUnqueued(manifests: await manifests.all(), queueStatus: await queuePort.status())
        })
        tasks.append(Task { await model.run() })
        tasks.append(Task { await env.relayQueueNotices() })
        tasks.append(Task { await env.relayOutputFolderNotices() })
        await env.retentionScheduler.start()
        // Nothing on the launch path waits for the permission prompt.
        tasks.append(Task { await notifier.requestAuthorization() })
        // Off the launch path: fill `claudePath` from the login shell when unset (ruling X8), then re-read readiness.
        let settings = env.settings
        Task.detached {
            _ = try? await ClaudeLocator.fillDefaultPath(settings)
            await model.refresh()
        }
        // Off the launch path: the first-run model download (never under an overridden data directory).
        let readiness = env.readiness, overridden = env.isDataDirectoryOverridden
        tasks.append(Task {
            if let name = await readiness.startFirstRunDownload(isDataDirectoryOverridden: overridden) {
                logger.info("first run: model download started \(name, privacy: .public)")
                NSLog("AutoNote: first run: model download started %@", name)
            } else if overridden {
                NSLog("AutoNote: first run: model download skipped (data directory overridden)")
            }
        })

        // 3. Crash recovery before automatic recording starts (§5.8, §8b (2)). A meeting started over the socket in
        //    the meantime is excluded. "はい" comes back through the notifier's onAction →
        //    `.notice(.recoverInterrupted(id))` → `meetings.recover` → `wiring.route`.
        do {
            let active = await env.coordinator.current().meetingID
            for manifest in try await env.crashRecovery.findInterrupted(excluding: active) {
                await env.notifier.post(.interruptedRecordingFound(manifest.id))
            }
        } catch {
            logger.error("crash recovery scan failed: \(String(describing: error), privacy: .public)")
        }
        let coordinator = env.coordinator
        tasks.append(Task { await coordinator.run() })

        let s = (try? await env.settings.load()) ?? AutoNoteCore.Settings()
        model.shortcuts = s.shortcuts

        // 4. On the very first run, the main window, so it lands somewhere to start from (later launches open nothing);
        // 5. then the microphone prompt while undetermined (plan 02 never asks).
        if !s.firstRunCompleted {
            logger.info("first run: opening the main window")
            shell.open(AppShell.mainWindowID)
            do { _ = try await settings.update { $0.firstRunCompleted = true } } catch {
                logger.error("could not save firstRunCompleted: \(String(describing: error), privacy: .public)")
            }
        }
        Self.requestMicrophoneIfUndetermined()

        // 6. Launch at login follows the setting (skipped under an overridden data directory, ruling X22).
        env.reconcileLoginItem(launchAtLogin: s.launchAtLogin)

        // 7. Global shortcuts; the settings screen re-applies them through `shortcutsChanged`.
        let hotKeys = HotKeyCenter { action in
            let user: UserAction = switch action {
            case .bookmark: .bookmark(nil)
            case .toggleRecording: .toggleRecording
            case .togglePause: .togglePause
            }
            Task { await model.perform(user) }
        }
        hotKeys.apply(s.shortcuts)
        env.shortcutsChanged = { hotKeys.apply($0) }
        self.hotKeys = hotKeys
        logger.info("launch finished (data: \(env.paths.root.path, privacy: .public))")
    }

    /// Writes the default output folder when none is set and logs what it did. Never throws: the launch goes on.
    private static func applyFirstRunDefaults(environment: [String: String]) async {
        let paths = AppPaths.resolve(environment: environment)
        try? paths.createBaseDirectories()
        let outcome = await FirstRunDefaults.apply(settings: SettingsStore(paths: paths), paths: paths,
                                                   isDataDirectoryOverridden: AppIdentity.isDataDirectoryOverridden(environment))
        switch outcome {
        case .created(let path):
            logger.info("first run: output folder \(path, privacy: .public)")
            NSLog("AutoNote: first run: output folder %@", path)
        case .failed:
            logger.error("first run: could not set the default output folder")
            NSLog("AutoNote: first run: could not set the default output folder")
        case .unchanged:
            break
        }
    }

    /// True when something answers on the socket. A path too long for a socket cannot be served by anyone.
    private static func isAnotherInstanceRunning(socketFile: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: socketFile.path) else { return false }
        let client = SocketClient(socketURL: socketFile, launcher: nil)
        do {
            _ = try await client.send(.status, args: IPCArgs(), responseTimeout: .seconds(2))
            return true
        } catch .appNotRunning {
            return false
        } catch .protocolError(let message) where message.hasPrefix("ソケットのパスが長すぎます") {
            return false
        } catch {
            return true   // connected, but the answer was late or malformed: someone is serving it
        }
    }

    private func showLaunchFailure(_ error: any Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "AutoNote を起動できません: \(error.localizedDescription)"
        alert.addButton(withTitle: "終了")
        alert.runModal()
    }

    /// Launch item 5: ask for the microphone only while undetermined; a denial shows up as a failed start later.
    private static func requestMicrophoneIfUndetermined() {
        guard AVMicrophonePermission().status() == .notDetermined else { return }
        logger.info("requesting microphone access")
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            logger.info("microphone access granted=\(granted, privacy: .public)")
        }
    }

    // MARK: - Quitting

    /// The longest a quit waits for the recording to stop and save.
    private static let stopTimeout: Duration = .seconds(10)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Read before anything activates the app: `didBecomeActive` puts the reason back to `.user`.
        let reason = quitReason
        guard let model = env?.model else { return .terminateNow }
        switch QuitPolicy.decide(model.recorder.state, reason: reason) {
        case .terminateNow:
            return .terminateNow
        case .cancelCountdownThenTerminate:
            replyAfter { await model.perform(.cancelCountdown) }
            return .terminateLater
        case .stopThenTerminate:
            logger.info("quitting while recording (\(String(describing: reason), privacy: .public)): stopping first")
            replyAfter { [env] in await Self.stopAndAwaitJob(model: model, env: env) }
            return .terminateLater
        case .confirm:
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = QuitPolicy.confirmMessage
            alert.addButton(withTitle: "停止して終了")
            alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn else {
                resetQuitReason()
                return .terminateCancel
            }
            replyAfter { [env] in await Self.stopAndAwaitJob(model: model, env: env) }
            return .terminateLater
        }
    }

    /// The longest a quit waits, after the stop, for the stopped meeting's queue job to be written (I2).
    private static let jobTimeout: Duration = .seconds(3)

    /// Stops, then waits (at most `jobTimeout`) until the stopped meeting has a queue job or left `.recorded`
    /// (e.g. too short), so a quit right after the stop does not leave a meeting without a job.
    private static func stopAndAwaitJob(model: AppModel, env: AppEnvironment?) async {
        let id = model.recorder.meetingID
        await model.perform(.stop)
        guard let id, let env else { return }
        let deadline = ContinuousClock.now + jobTimeout
        while ContinuousClock.now < deadline {
            if await env.ports.queue.status().items.contains(where: { $0.meetingID == id.rawValue }) { return }
            if let m = try? await env.manifests.load(id), m.status != .recorded { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        logger.error("quit: \(id.rawValue, privacy: .public) has no queue job yet; the launch sweep will enqueue it")
    }

    /// Runs `work`, then lets the pending `.terminateLater` go ahead — after at most `stopTimeout` either way.
    private func replyAfter(_ work: @escaping @MainActor () async -> Void) {
        let reply = ReplyOnce()
        Task { @MainActor in
            await work()
            reply.terminate()
        }
        Task { @MainActor in
            try? await Task.sleep(for: Self.stopTimeout)
            if !reply.done { logger.error("stop did not finish in time; quitting anyway") }
            reply.terminate()
        }
    }

    /// Back to a user quit, e.g. after a power-off was cancelled.
    func resetQuitReason() { quitReason = .user }

    func applicationWillTerminate(_ notification: Notification) {
        guard let server = env?.server else { return }
        // The socket file must be gone when the process exits (E2E 06.6); wait briefly for the actor.
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await server.stop()
            done.signal()
        }
        if done.wait(timeout: .now() + 2) == .timedOut {
            logger.error("socket server did not stop in time")
        }
    }

    /// SIGTERM (default handling ignored, then caught) and power-off both quit with `reason = .powerOff`.
    private func installTerminationSignals() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                logger.info("SIGTERM received; terminating")
                self?.quitReason = .powerOff
                NSApp.terminate(nil)
            }
        }
        source.resume()
        sigtermSource = source
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.quitReason = .powerOff }
        })
        // A shutdown the user cancelled leaves the app running; the next activation is a normal session again.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetQuitReason() }
        })
    }
}

/// `NSApp.reply(toApplicationShouldTerminate: true)` exactly once.
@MainActor
private final class ReplyOnce {
    private(set) var done = false

    func terminate() {
        guard !done else { return }
        done = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
