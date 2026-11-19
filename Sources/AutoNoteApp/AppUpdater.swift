import AppKit
import AutoNoteCore
import Foundation
import Observation
import os

private let logger = Logger(subsystem: AppIdentity.bundleID, category: "AppUpdater")

/// The daily update check and the swap (spec: アプリ内の自動アップデート). Core decides (`UpdateChecker`,
/// `UpdateInstallGate`); this type keeps the status the settings and the menu show, re-asks the gate while an update
/// waits, and starts the helper and quits when the gate says yes.
@MainActor @Observable
final class AppUpdater {
    private(set) var status: UpdateStatus = .idle
    private(set) var lastCheckedAt: Date?
    private(set) var enabled = true
    /// What the helper reported for the swap before this launch, once.
    private(set) var lastInstall: UpdateInstallResult?
    let currentVersion: String

    /// Set by the environment once the model exists; the gate reads the recorder, the queue and translation jobs.
    @ObservationIgnored var model: AppModel? { didSet { publishMenu() } }
    /// Set by AppDelegate (`AppShell.isMainWindowOpen`).
    @ObservationIgnored var isMainWindowOpen: @MainActor () -> Bool = { false }
    /// The recorder's state read from the coordinator itself (the model's copy arrives by subscription, a moment
    /// late), asked once more right before the quit (review L2).
    @ObservationIgnored var recorderState: @MainActor () async -> RecorderState? = { nil }
    /// Downloads, imports and Automations in progress (review L4); set by the environment.
    @ObservationIgnored var busyWork: @MainActor () async -> UpdateBusyWork = { .none }

    @ObservationIgnored private let checker: UpdateChecker
    @ObservationIgnored private let store: UpdateStateStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private var staged: StagedUpdate?
    @ObservationIgnored private var scheduler: UpdateScheduler?
    @ObservationIgnored private var gateTask: Task<Void, Never>?
    @ObservationIgnored private var busy = false
    /// The swap to start from `applicationWillTerminate`, once the quit is certain (review L2).
    @ObservationIgnored private var pendingPlan: UpdateInstallPlan?
    @ObservationIgnored private var quitWatchdog: Task<Void, Never>?

    /// How often a waiting update asks the gate again.
    private static let gateInterval: Duration = .seconds(10)

    init(paths: AppPaths, settings: SettingsStore, environment: [String: String]) {
        let runningApp = BundleFacts.enclosingApp(ofExecutable: Bundle.main.executableURL
            ?? URL(filePath: CommandLine.arguments[0]))
        let feed = UpdateContext.feed(environment: environment, debugBuild: UpdateContext.isDebugBuild)
        let version = UpdateContext.currentVersion(runningApp: runningApp)
        let directory = paths.root.appending(path: "updates", directoryHint: .isDirectory)
        checker = UpdateChecker(context: UpdateContext(
            feedURL: feed.url, policy: feed.policy, currentVersion: version, bundleID: AppIdentity.bundleID,
            runningApp: runningApp, directory: directory, requirementFromProcess: true))
        store = UpdateStateStore(directory: directory)
        self.settings = settings
        self.environment = environment
        currentVersion = version.description
        if feed.policy == .development {
            NSLog("AutoNote: update: development feed %@", feed.url.absoluteString)
        }
        // Started by the helper after a swap: tell it this process is up (it waits for the pid).
        UpdateInstaller.writeLaunchMarker(environment: environment, directory: directory)
    }

    /// Launch: report the previous swap, clear old downloads, then the daily schedule.
    func start() async {
        let state = await store.load()
        lastCheckedAt = state.lastCheckedAt
        enabled = (try? await settings.load().autoUpdateEnabled) ?? true
        if let result = await store.takeInstallResult() {
            lastInstall = result
            await record(result)
        }
        checker.removeStaleDownloads()
        if let target = checker.context.runningApp {
            for left in UpdateInstaller.sweepLeftovers(target: target, lockDirectory: lockDirectory) {
                NSLog("AutoNote: update: removed %@ left by an interrupted swap", left.path)
            }
        }
        if !enabled { status = .disabled }
        let store = store, settings = settings
        let scheduler = UpdateScheduler(
            isEnabled: { (try? await settings.load().autoUpdateEnabled) ?? true },
            lastCheckedAt: { await store.load().lastCheckedAt },
            retryAt: { await store.load().retryAt },
            check: { [weak self] in await self?.check(manual: false) })
        self.scheduler = scheduler
        await scheduler.start()
    }

    private func record(_ result: UpdateInstallResult) async {
        switch result.result {
        case .installed:
            logger.notice("update: installed \(result.to, privacy: .public) (from \(result.from, privacy: .public))")
            NSLog("AutoNote: update: installed %@ (from %@); login item status %@", result.to, result.from,
                  String(describing: LoginItem.status.rawValue))
            status = .upToDate
        case .restored, .skipped:
            let failure = UpdateFailure.installFailed(version: result.to, reason: result.reasonText)
            logger.error("update: swap to \(result.to, privacy: .public) failed (\(result.reason, privacy: .public)); old version kept")
            NSLog("AutoNote: update: swap to %@ failed (%@); old version kept", result.to, result.reason)
            // Not tried again automatically; 「今すぐ確認」 clears it.
            if result.result == .restored { _ = try? await store.update { $0.failedVersion = result.to } }
            status = .failed(failure.message)
        }
    }

    /// The settings switch. Off drops a waiting update; on checks when due.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            status = .idle
            Task {
                let state = await store.load()
                if UpdateSchedule.isDue(lastCheckedAt: state.lastCheckedAt, retryAt: state.retryAt, now: Date()) {
                    await check(manual: false)
                }
            }
        } else {
            staged = nil
            gateTask?.cancel()
            gateTask = nil
            status = .disabled
        }
        publishMenu()
    }

    /// One check: the feed, then (when newer) download and verify, then the gate. `manual` is 「今すぐ確認」: runs even
    /// when switched off and retries a version whose swap failed before.
    func check(manual: Bool) async {
        guard !busy else { return }
        guard manual || enabled else { return }
        if case .installing = status { return }
        busy = true
        defer { busy = false; publishMenu() }
        if manual { _ = try? await store.update { $0.failedVersion = nil } }
        status = .checking
        publishMenu()
        let outcome: UpdateCheckOutcome
        do {
            outcome = try await checker.check()
        } catch {
            NSLog("AutoNote: update: check failed (%@)", String(describing: error))
            if error == .network {
                // Not reached: try again after a growing wait (1, 2, 4… hours, then daily; review L7). The last
                // check time is not moved.
                let now = Date()
                let state = try? await store.update {
                    $0.networkFailures += 1
                    $0.retryAt = now.addingTimeInterval(UpdateSchedule.retryDelay(failures: $0.networkFailures))
                }
                NSLog("AutoNote: update: no connection (%d in a row); next try %@", state?.networkFailures ?? 0,
                      String(describing: state?.retryAt))
            }
            if error == .network && !manual {
                if let staged { status = .readyToInstall(version: staged.version.description, waiting: nil) } else { status = .idle }
            } else {
                status = .failed(error.message)
            }
            if error != .network { await markChecked() }
            return
        }
        await markChecked()
        switch outcome {
        case .upToDate(let latest):
            NSLog("AutoNote: update: up to date (latest %@, running %@)", latest.description, currentVersion)
            staged = nil
            status = .upToDate
        case .available(let release):
            await download(release, manual: manual)
        }
    }

    private func markChecked() async {
        let now = Date()
        lastCheckedAt = now
        _ = try? await store.update {
            $0.lastCheckedAt = now
            $0.networkFailures = 0
            $0.retryAt = nil
        }
    }

    private func download(_ release: UpdateRelease, manual: Bool) async {
        let version = release.version.description
        if !manual, await store.load().failedVersion == version {
            status = .failed(UpdateFailure.installFailed(version: version, reason: "前回").message)
            return
        }
        if let staged, staged.version == release.version, FileManager.default.fileExists(atPath: staged.app.path) {
            status = .readyToInstall(version: version, waiting: nil)
            await evaluateGate(userRequested: false)
            return
        }
        // Up front: a swap that can never work is a manual update, not a download.
        do throws(UpdateFailure) {
            let (app, _) = try checker.runningRequirement()
            if let problem = UpdateChecker.writableProblem(app: app) { throw problem }
        } catch {
            NSLog("AutoNote: update: %@ available but needs a manual update (%@)", version, String(describing: error))
            status = .manualRequired(error.message)
            return
        }
        NSLog("AutoNote: update: downloading %@", version)
        status = .downloading(version: version, fraction: nil)
        publishMenu()
        do {
            let staged = try await checker.prepare(release) { written, expected in
                guard expected > 0 else { return }
                let fraction = Double(written) / Double(expected)
                Task { @MainActor [weak self] in
                    if case .downloading = self?.status { self?.status = .downloading(version: version, fraction: fraction) }
                }
            }
            self.staged = staged
            NSLog("AutoNote: update: %@ verified (signature matches the running app)", version)
            status = .readyToInstall(version: version, waiting: nil)
            await evaluateGate(userRequested: false)
        } catch {
            NSLog("AutoNote: update: %@ refused (%@)", version, String(describing: error))
            status = .failed(error.message)
        }
    }

    /// 「アップデートして再起動」: now unless a recording is going on.
    func installNow() {
        Task { await evaluateGate(userRequested: true) }
    }

    /// Asks the gate; installs, or waits and asks again every `gateInterval`.
    private func evaluateGate(userRequested: Bool) async {
        guard let staged, enabled || userRequested, pendingPlan == nil else { return }
        let version = staged.version.description
        let decision: UpdateInstallGate.Decision
        if let model {
            let recorder = await recorderState() ?? model.recorder.state
            decision = UpdateInstallGate.decide(recorder: recorder, queue: model.queue.items,
                                                translationJobs: Array(model.translationJobs.values),
                                                busy: await busyWork(), mainWindowOpen: isMainWindowOpen(),
                                                userRequested: userRequested)
        } else {
            decision = .wait("起動中です")
        }
        // The awaits above may have let the staged update go (switched off, a newer check) or start installing.
        guard self.staged == staged, pendingPlan == nil else { return }
        switch decision {
        case .install:
            await install(staged)
        case .wait(let reason):
            if status != .readyToInstall(version: version, waiting: reason) {
                NSLog("AutoNote: update: %@ waiting (%@)", version, reason)
            }
            status = .readyToInstall(version: version, waiting: reason)
            publishMenu()
            guard gateTask == nil else { return }
            gateTask = Task { [weak self] in
                try? await Task.sleep(for: Self.gateInterval)
                guard let self, !Task.isCancelled else { return }
                self.gateTask = nil
                await self.evaluateGate(userRequested: false)
            }
        }
    }

    private var lockDirectory: URL { checker.context.directory.appending(path: "install.lock", directoryHint: .isDirectory) }

    /// Checks the staged app once more, then quits. The helper starts from `applicationWillTerminate`, so a quit that
    /// is cancelled leaves nothing running that could swap or relaunch later (review L2).
    private func install(_ staged: StagedUpdate) async {
        gateTask?.cancel()
        gateTask = nil
        guard let target = checker.context.runningApp else {
            status = .manualRequired(UpdateFailure.notInstalledApp.message)
            return
        }
        // It may have waited for days in a folder the person can write (review L1).
        do throws(UpdateFailure) {
            try checker.verifyStaged(staged)
        } catch {
            NSLog("AutoNote: update: staged %@ refused on the second check (%@)", staged.version.description,
                  String(describing: error))
            self.staged = nil
            status = .failed(error.message)
            return
        }
        guard !UpdateInstaller.helperIsRunning(lockDirectory: lockDirectory) else {
            NSLog("AutoNote: update: a helper is already running; not starting another")
            return
        }
        pendingPlan = UpdateInstallPlan(
            pid: ProcessInfo.processInfo.processIdentifier, target: target, staged: staged.app,
            requirement: staged.requirement, directory: checker.context.directory, fromVersion: currentVersion,
            toVersion: staged.version.description, environment: UpdateInstallPlan.relaunchEnvironment(environment))
        NSLog("AutoNote: update: installing %@; quitting for the swap", staged.version.description)
        status = .installing(version: staged.version.description)
        publishMenu()
        NSApp.terminate(nil)
        // Still here: the quit was cancelled or is waiting (a recording stopping takes at most ~13 s). If it has not
        // happened in a while, it is not going to.
        quitWatchdog?.cancel()
        quitWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.terminationCancelled()
        }
    }

    /// From `applicationWillTerminate`: the quit is certain, so the helper starts now and waits for this pid.
    func launchPendingHelper() {
        guard let plan = pendingPlan else { return }
        quitWatchdog?.cancel()
        do {
            try UpdateInstaller.launch(plan, directory: checker.context.directory)
            NSLog("AutoNote: update: helper started for %@", plan.toVersion)
        } catch {
            NSLog("AutoNote: update: helper did not start (%@)", String(describing: error))
        }
    }

    /// The quit for the swap was cancelled (the person chose キャンセル, or it never came): back to waiting.
    func terminationCancelled() {
        guard let plan = pendingPlan else { return }
        pendingPlan = nil
        quitWatchdog?.cancel()
        quitWatchdog = nil
        NSLog("AutoNote: update: quit for %@ was cancelled; waiting again", plan.toVersion)
        // Not asked again at once (that could quit again and again): the menu item stays, and the next check asks.
        status = .readyToInstall(version: plan.toVersion, waiting: nil)
        publishMenu()
    }

    private func publishMenu() {
        model?.updateMenuItem = status.menuItem
    }

    var dto: UpdateStatusDTO {
        UpdateStatusDTO(status: status, currentVersion: currentVersion, enabled: enabled, lastCheckedAt: lastCheckedAt,
                        lastInstall: lastInstall)
    }
}

/// The socket's view of the updater (`update.status`, `update.check`).
struct AppUpdatePort: UpdatePort {
    let updater: AppUpdater

    func status() async -> UpdateStatusDTO { await updater.dto }

    func checkNow() async -> UpdateStatusDTO {
        await updater.check(manual: true)
        return await updater.dto
    }
}
