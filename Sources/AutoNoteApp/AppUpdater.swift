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

    @ObservationIgnored private let checker: UpdateChecker
    @ObservationIgnored private let store: UpdateStateStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private var staged: StagedUpdate?
    @ObservationIgnored private var scheduler: UpdateScheduler?
    @ObservationIgnored private var gateTask: Task<Void, Never>?
    @ObservationIgnored private var busy = false

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
        if !enabled { status = .disabled }
        let store = store, settings = settings
        let scheduler = UpdateScheduler(
            isEnabled: { (try? await settings.load().autoUpdateEnabled) ?? true },
            lastCheckedAt: { await store.load().lastCheckedAt },
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
            if UpdateSchedule.isDue(lastCheckedAt: lastCheckedAt, now: Date()) { Task { await check(manual: false) } }
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
            if error == .network && !manual {
                // Quiet: the next hourly tick tries again (the last check time is not moved).
                if staged == nil { status = .idle } else { status = .readyToInstall(version: staged!.version.description, waiting: nil) }
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
        _ = try? await store.update { $0.lastCheckedAt = now }
    }

    private func download(_ release: UpdateRelease, manual: Bool) async {
        let version = release.version.description
        if !manual, await store.load().failedVersion == version {
            status = .failed(UpdateFailure.installFailed(version: version, reason: "前回").message)
            return
        }
        if let staged, staged.version == release.version, FileManager.default.fileExists(atPath: staged.app.path) {
            status = .readyToInstall(version: version, waiting: nil)
            evaluateGate(userRequested: false)
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
            evaluateGate(userRequested: false)
        } catch {
            NSLog("AutoNote: update: %@ refused (%@)", version, String(describing: error))
            status = .failed(error.message)
        }
    }

    /// 「アップデートして再起動」: now unless a recording is going on.
    func installNow() {
        evaluateGate(userRequested: true)
    }

    /// Asks the gate; installs, or waits and asks again every `gateInterval`.
    private func evaluateGate(userRequested: Bool) {
        guard let staged, enabled || userRequested else { return }
        let version = staged.version.description
        let decision: UpdateInstallGate.Decision
        if let model {
            decision = UpdateInstallGate.decide(recorder: model.recorder.state, queue: model.queue.items,
                                                translationJobs: Array(model.translationJobs.values),
                                                mainWindowOpen: isMainWindowOpen(), userRequested: userRequested)
        } else {
            decision = .wait("起動中です")
        }
        switch decision {
        case .install:
            install(staged)
        case .wait(let reason):
            if status != .readyToInstall(version: version, waiting: reason) {
                NSLog("AutoNote: update: %@ waiting (%@)", version, reason)
            }
            status = .readyToInstall(version: version, waiting: reason)
            publishMenu()
            guard gateTask == nil else { return }
            gateTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.gateInterval)
                    guard let self, !Task.isCancelled else { return }
                    self.gateTask = nil
                    self.evaluateGate(userRequested: false)
                    return
                }
            }
        }
    }

    private func install(_ staged: StagedUpdate) {
        gateTask?.cancel()
        gateTask = nil
        guard let target = checker.context.runningApp else {
            status = .manualRequired(UpdateFailure.notInstalledApp.message)
            return
        }
        let plan = UpdateInstallPlan(
            pid: ProcessInfo.processInfo.processIdentifier, target: target, staged: staged.app,
            requirement: staged.requirement, resultFile: checker.context.directory.appending(path: "last-install.json"),
            logFile: checker.context.directory.appending(path: "install.log"), fromVersion: currentVersion,
            toVersion: staged.version.description, environment: UpdateInstallPlan.relaunchEnvironment(environment))
        do {
            try UpdateInstaller.launch(plan, directory: checker.context.directory)
        } catch {
            NSLog("AutoNote: update: helper did not start (%@)", String(describing: error))
            status = .failed(UpdateFailure.installFailed(version: plan.toVersion, reason: "補助を起動できませんでした").message)
            return
        }
        NSLog("AutoNote: update: installing %@; quitting for the swap", plan.toVersion)
        status = .installing(version: plan.toVersion)
        publishMenu()
        NSApp.terminate(nil)
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
