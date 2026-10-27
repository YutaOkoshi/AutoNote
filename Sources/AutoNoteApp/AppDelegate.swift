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

    /// Why the app is quitting: `.powerOff` for SIGTERM and `NSWorkspace.willPowerOffNotification`. A power-off
    /// that was cancelled puts it back to `.user` (`resetQuitReason`).
    private(set) var quitReason: QuitReason = .user

    private var sigtermSource: (any DispatchSourceSignal)?
    private var observers: [any NSObjectProtocol] = []
    private var tasks: [Task<Void, Never>] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationSignals()
        Task { await launch() }
    }

    private func launch() async {
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
            env = try await AppEnvironment.make(environment: environment)
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

        // 2. Subscriptions start right away: the socket already accepts commands (ruling X48).
        let wiring = env.wiring, queue = env.queue, model = env.model
        tasks.append(Task { await wiring.run() })
        tasks.append(Task { await queue.queue.start() })
        tasks.append(Task { await model.run() })
        tasks.append(Task { await env.relayQueueNotices() })
        tasks.append(Task { await env.relayOutputFolderNotices() })
        await env.retentionScheduler.start()
        // Nothing on the launch path waits for the permission prompt.
        let notifier = env.notifier
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

        // 13c: items 4 (consent window) and 5 (microphone permission)

        // 6. Launch at login follows the setting (skipped under an overridden data directory, ruling X22).
        let s = (try? await env.settings.load()) ?? AutoNoteCore.Settings()
        env.reconcileLoginItem(launchAtLogin: s.launchAtLogin)

        // 13c: item 7 (HotKeyCenter.apply(s.shortcuts), and env.shortcutsChanged)
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

    // 13c: applicationShouldTerminate (QuitPolicy.decide(model.recorder.state, reason: quitReason), NSAlert, stop);
    //      call resetQuitReason() when it returns .terminateCancel.

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
