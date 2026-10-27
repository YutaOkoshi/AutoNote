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

    /// Why the app is quitting: `.powerOff` for SIGTERM and `NSWorkspace.willPowerOffNotification`.
    private(set) var quitReason: QuitReason = .user

    private var sigtermSource: (any DispatchSourceSignal)?
    private var powerOffObserver: (any NSObjectProtocol)?
    private var tasks: [Task<Void, Never>] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationSignals()
        Task { await launch() }
    }

    private func launch() async {
        let environment = ProcessInfo.processInfo.environment

        // 1. Build the services; a second instance (socket answered) quits.
        let env: AppEnvironment
        do {
            env = try await AppEnvironment.make(environment: environment)
        } catch {
            logger.error("launch failed: \(String(describing: error), privacy: .public)")
            NSLog("AutoNote: launch failed: %@", String(describing: error))
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

        // Off the launch path: fill `claudePath` from the login shell when unset (ruling X8).
        let settings = env.settings
        Task.detached { _ = try? await ClaudeLocator.fillDefaultPath(settings) }

        // 2. Notifications, the long-running loops and retention.
        await env.notifier.requestAuthorization()
        let wiring = env.wiring, queue = env.queue, model = env.model, retention = env.retentionScheduler
        tasks.append(Task.detached { await wiring.run() })
        tasks.append(Task.detached { await queue.queue.start() })
        tasks.append(Task { await model.run() })
        tasks.append(Task { await env.relayQueueNotices() })
        tasks.append(Task { await env.relayOutputFolderNotices() })
        await retention.start()

        // 3. Crash recovery before any recording can start (§5.8, §8b (2)). "はい" comes back through the
        //    notifier's onAction → `.notice(.recoverInterrupted(id))` → `meetings.recover` → `wiring.route`.
        do {
            for manifest in try await env.crashRecovery.findInterrupted(excluding: nil) {
                await env.notifier.post(.interruptedRecordingFound(manifest.id))
            }
        } catch {
            logger.error("crash recovery scan failed: \(String(describing: error), privacy: .public)")
        }
        let coordinator = env.coordinator
        tasks.append(Task.detached { await coordinator.run() })

        // 13c: items 4 (consent window) and 5 (microphone permission)

        // 6. Launch at login follows the setting (skipped under an overridden data directory, ruling X22).
        let s = (try? await env.settings.load()) ?? AutoNoteCore.Settings()
        env.reconcileLoginItem(launchAtLogin: s.launchAtLogin)

        // 13c: item 7 (HotKeyCenter.apply(s.shortcuts), and env.shortcutsChanged)
        logger.info("launch finished (data: \(env.paths.root.path, privacy: .public))")
    }

    // 13c: applicationShouldTerminate (QuitPolicy.decide(model.recorder.state, reason: quitReason), NSAlert, stop)

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

    /// SIGTERM (ignored by default handling, then caught) and power-off both quit with `reason = .powerOff`.
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
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.quitReason = .powerOff }
        }
    }
}
