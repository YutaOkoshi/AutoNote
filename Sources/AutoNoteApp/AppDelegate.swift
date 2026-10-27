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

        // 2. Subscriptions start right away: the socket already accepts commands (ruling X48).
        let wiring = env.wiring, queue = env.queue, model = env.model
        tasks.append(Task { await wiring.run() })
        tasks.append(Task { await queue.queue.start() })
        tasks.append(Task { await model.run() })
        tasks.append(Task { await env.relayQueueNotices() })
        tasks.append(Task { await env.relayOutputFolderNotices() })
        await env.retentionScheduler.start()
        // Nothing on the launch path waits for the permission prompt.
        tasks.append(Task { await notifier.requestAuthorization() })
        // Off the launch path: fill `claudePath` from the login shell when unset (ruling X8).
        let settings = env.settings
        Task.detached { _ = try? await ClaudeLocator.fillDefaultPath(settings) }

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

        // 4. The consent notice once (§11.6); 5. the microphone prompt after its OK (plan 02 never asks).
        shell.consentAccepted = { [settings] in
            Task {
                do { _ = try await settings.update { $0.consentNoticeShown = true } } catch {
                    logger.error("could not save consentNoticeShown: \(String(describing: error), privacy: .public)")
                }
                Self.requestMicrophoneIfUndetermined()
            }
        }
        if s.consentNoticeShown {
            Self.requestMicrophoneIfUndetermined()
        } else {
            logger.info("showing the consent notice")
            shell.open(AppShell.consentWindowID)
        }

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
            replyAfter { await model.perform(.stop) }
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
            replyAfter { await model.perform(.stop) }
            return .terminateLater
        }
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
