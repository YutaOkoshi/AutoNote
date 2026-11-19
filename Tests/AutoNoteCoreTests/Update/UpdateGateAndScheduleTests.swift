import Foundation
import Testing
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct UpdateInstallGateTests {
    func job(_ state: JobState) -> QueueItemDTO {
        QueueItemDTO(meetingID: "20261024-1400-a1b2", stage: "summarize", state: state.rawValue, progress: nil, label: "",
                     message: nil, awaitingConfirmation: false, summaryFailure: nil, generation: 1, notBefore: nil)
    }

    func decide(_ r: RecorderState = .idle, queue: [QueueItemDTO] = [], translation: [TranslationJobState] = [],
                busy: UpdateBusyWork = .none, window: Bool = false, user: Bool = false) -> UpdateInstallGate.Decision {
        UpdateInstallGate.decide(recorder: r, queue: queue, translationJobs: translation, busy: busy, mainWindowOpen: window,
                                 userRequested: user)
    }

    @Test func waitsForDownloadsImportsAndAutomationsUnlessAsked() {
        #expect(decide(busy: UpdateBusyWork(audioImport: true)) == .wait("音声を取り込んでいます"))
        #expect(decide(busy: UpdateBusyWork(modelDownload: true)) == .wait("モデルをダウンロードしています"))
        #expect(decide(busy: UpdateBusyWork(automation: true)) == .wait("Automation を実行しています"))
        #expect(decide(busy: UpdateBusyWork(modelDownload: true, audioImport: true, automation: true), user: true) == .install)
        #expect(decide(.recording, busy: UpdateBusyWork(automation: true), user: true) == .wait("録音中です"))
    }

    @Test func installsWhenNothingIsGoingOn() {
        #expect(decide() == .install)
        #expect(decide(queue: [job(.done), job(.failed), job(.waiting)], translation: [.failed("x")]) == .install)
    }

    @Test func neverDuringARecordingEvenWhenAsked() {
        for state in [RecorderState.countdown, .recording, .paused, .grace] {
            #expect(decide(state) != .install, "\(state)")
            #expect(decide(state, user: true) != .install, "\(state)")
        }
        #expect(decide(.recording) == .wait("録音中です"))
    }

    @Test func waitsForJobsAndTheWindowUnlessAsked() {
        let p = TranslationProgress(done: 1, total: 3)
        #expect(decide(queue: [job(.pending)]) == .wait("議事録を作っています"))
        #expect(decide(queue: [job(.running)]) == .wait("議事録を作っています"))
        for t in [TranslationJobState.queued, .running(p), .waitingForRecording(p), .waitingForTranscription(p)] {
            #expect(decide(translation: [t]) == .wait("翻訳しています"))
        }
        #expect(decide(window: true) == .wait("ウィンドウを閉じると再起動します"))
        #expect(decide(queue: [job(.running)], translation: [.queued], window: true, user: true) == .install)
    }
}

@Suite struct UpdateScheduleTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func dueWhenNeverCheckedOrADayPassed() {
        #expect(UpdateSchedule.isDue(lastCheckedAt: nil, now: t0))
        #expect(!UpdateSchedule.isDue(lastCheckedAt: t0, now: t0.addingTimeInterval(86_399)))
        #expect(UpdateSchedule.isDue(lastCheckedAt: t0, now: t0.addingTimeInterval(86_400)))
        // The clock went back by more than a minute: check rather than wait for a day that may never come.
        #expect(UpdateSchedule.isDue(lastCheckedAt: t0.addingTimeInterval(3_600), now: t0))
        #expect(!UpdateSchedule.isDue(lastCheckedAt: t0.addingTimeInterval(30), now: t0))
    }

    @Test func afterNoConnectionTheWaitDoublesUpToADay() {
        #expect([1, 2, 3, 4, 5, 6, 20].map { UpdateSchedule.retryDelay(failures: $0) }
            == [3_600, 7_200, 14_400, 28_800, 57_600, 86_400, 86_400])
        // The retry time replaces the daily deadline, both ways.
        #expect(!UpdateSchedule.isDue(lastCheckedAt: nil, retryAt: t0.addingTimeInterval(3_600), now: t0))
        #expect(UpdateSchedule.isDue(lastCheckedAt: t0, retryAt: t0.addingTimeInterval(3_600), now: t0.addingTimeInterval(3_600)))
        // A clock set far back does not wait for it.
        #expect(UpdateSchedule.isDue(lastCheckedAt: nil, retryAt: t0.addingTimeInterval(200_000), now: t0))
    }

    @Test func schedulerFollowsTheRetryTime() async throws {
        let clock = FakeQueueClock(now: t0)
        let log = CheckLog()
        await log.setRetry(t0.addingTimeInterval(7_200))
        let scheduler = UpdateScheduler(clock: clock, tick: 3_600, isEnabled: { true }, lastCheckedAt: { nil },
                                        retryAt: { await log.retry }, check: { await log.check(clock.now()) })
        await scheduler.start()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await log.count == 0)
        clock.advance(by: 3_600)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await log.count == 0)
        clock.advance(by: 3_600)
        try await waitFor { await log.count == 1 }
        await scheduler.stop()
    }

    @Test func schedulerChecksAtStartThenOnceADayAndNotWhenOff() async throws {
        let clock = FakeQueueClock(now: t0)
        let log = CheckLog()
        let scheduler = UpdateScheduler(clock: clock, tick: 3_600, isEnabled: { await log.enabled },
                                        lastCheckedAt: { await log.last }, check: { await log.check(clock.now()) })
        await scheduler.start()
        try await waitFor { await log.count == 1 }
        for _ in 0..<23 {
            clock.advance(by: 3_600)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await log.count == 1)
        clock.advance(by: 3_600)
        try await waitFor { await log.count == 2 }
        await log.setEnabled(false)
        for _ in 0..<30 {
            clock.advance(by: 3_600)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await log.count == 2)
        await scheduler.stop()
    }

    private func waitFor(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition not met")
    }
}

private actor CheckLog {
    var count = 0
    var last: Date?
    var enabled = true
    var retry: Date?
    func check(_ now: Date) { count += 1; last = now; retry = nil }
    func setRetry(_ at: Date) { retry = at }
    func setEnabled(_ on: Bool) { enabled = on }
}

@Suite struct UpdateStateStoreTests {
    @Test func roundTripsAndReadsTheInstallResultOnce() async throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UpdateStateStore(directory: dir.appending(path: "updates"))
        #expect(await store.load() == UpdateState())
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.update { $0.lastCheckedAt = when; $0.failedVersion = "0.7.0" }
        #expect(await store.load() == UpdateState(lastCheckedAt: when, failedVersion: "0.7.0"))
        try await store.update { $0.networkFailures = 2; $0.retryAt = when }
        let retrying = await store.load()
        #expect(retrying.networkFailures == 2 && retrying.retryAt == when)
        // A state file from before the retry fields still reads.
        let old = try AutoNoteJSON.decoder().decode(UpdateState.self, from: Data(#"{"failed_version":"0.7.0"}"#.utf8))
        #expect(old == UpdateState(failedVersion: "0.7.0"))

        // The helper's own line format.
        try Data(#"{"from":"0.6.0","to":"0.7.0","result":"restored","reason":"launch"}"#.utf8)
            .write(to: await store.resultFile)
        let r = await store.takeInstallResult()
        #expect(r == UpdateInstallResult(from: "0.6.0", to: "0.7.0", result: .restored, reason: "launch"))
        #expect(r?.reasonText == "新しいアプリを起動できませんでした")
        #expect(await store.takeInstallResult() == nil)
    }
}

@Suite struct UpdateInstallPlanTests {
    @Test func swapSlotSitsNextToTheAppAndArgumentsAreOrdered() {
        var plan = UpdateInstallPlan(
            pid: 42, target: URL(filePath: "/Applications/AutoNote.app"), staged: URL(filePath: "/tmp/u/0.7.0/unpacked/AutoNote.app"),
            requirement: #"identifier "x" and certificate leaf = H"ab""#, directory: URL(filePath: "/tmp/u"),
            fromVersion: "0.6.0", toVersion: "0.7.0",
            environment: ["AUTONOTE_UPDATE_FEED_URL": "http://x", "AUTONOTE_DATA_DIR": "/tmp/d"])
        #expect(plan.swapPath.path == "/Applications/.AutoNote-update.app")
        plan.launchCheckSeconds = 3
        #expect(plan.arguments == ["42", "/Applications/AutoNote.app", "/tmp/u/0.7.0/unpacked/AutoNote.app",
                                   "/Applications/.AutoNote-update.app", #"identifier "x" and certificate leaf = H"ab""#,
                                   "/tmp/u/last-install.json", "/tmp/u/install.log", "/tmp/u/launched.pid", "/tmp/u/install.lock",
                                   "0.6.0", "0.7.0", "60", "3",
                                   "AUTONOTE_DATA_DIR=/tmp/d", "AUTONOTE_UPDATE_FEED_URL=http://x"])
    }

    @Test func onlyAutoNoteVariablesTravelToTheRelaunch() {
        let env = UpdateInstallPlan.relaunchEnvironment(["AUTONOTE_DATA_DIR": "/d", "HOME": "/Users/x", "GH_TOKEN": "t",
                                                         "AUTONOTE_UPDATE_LAUNCH_MARKER": "/d/updates/launched.pid"])
        #expect(env == ["AUTONOTE_DATA_DIR": "/d"])
    }

    @Test func helperScriptIsValidBash() throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "install.sh")
        try Data(UpdateInstaller.script.utf8).write(to: file)
        let p = Process()
        p.executableURL = URL(filePath: "/bin/bash")
        p.arguments = ["-n", file.path]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test func swapExchangesTwoFoldersInOneStep() throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "A.app"), b = dir.appending(path: ".A-update.app")
        try writeApp(a, bundleID: "x", version: "1")
        try writeApp(b, bundleID: "x", version: "2")
        try UpdateInstaller.swap(a, b)
        #expect(BundleFacts.read(a)?.shortVersion == "2")
        #expect(BundleFacts.read(b)?.shortVersion == "1")
        #expect(throws: UpdateSwapError.self) { try UpdateInstaller.swap(a, dir.appending(path: "missing")) }
        #expect(BundleFacts.read(a)?.shortVersion == "2")
    }

    @Test func leftoversAreSweptOnlyWhenNoHelperRuns() throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appending(path: "AutoNote.app")
        try writeApp(target, bundleID: "x", version: "1")
        let slot = UpdateInstallPlan.swapPath(for: target), legacy = UpdateInstallPlan.legacyBackupPath(for: target)
        try writeApp(slot, bundleID: "x", version: "0")
        try writeApp(legacy, bundleID: "x", version: "0")
        let lock = dir.appending(path: "install.lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: lock.appending(path: "pid"))
        #expect(UpdateInstaller.sweepLeftovers(target: target, lockDirectory: lock).isEmpty)
        try Data("999999".utf8).write(to: lock.appending(path: "pid"))
        #expect(UpdateInstaller.sweepLeftovers(target: target, lockDirectory: lock).count == 2)
        #expect(!FileManager.default.fileExists(atPath: slot.path) && !FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func theLaunchMarkerIsWrittenOnlyIntoTheOwnUpdatesFolder() throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let updates = dir.appending(path: "updates")
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        let elsewhere = dir.appending(path: "elsewhere.pid")
        UpdateInstaller.writeLaunchMarker(environment: [UpdateInstallPlan.launchMarkerKey: elsewhere.path], directory: updates, pid: 7)
        #expect(!FileManager.default.fileExists(atPath: elsewhere.path))
        let marker = updates.appending(path: "launched.pid")
        UpdateInstaller.writeLaunchMarker(environment: [UpdateInstallPlan.launchMarkerKey: marker.path], directory: updates, pid: 7)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "7\n")
    }
}

@Suite struct UpdatePresentationTests {
    @Test func statusTextsAndMenuItems() {
        #expect(UpdateStatus.readyToInstall(version: "0.7.0", waiting: "録音中です").text
            == "0.7.0 に更新できます。再起動を待っています（録音中です）")
        #expect(UpdateStatus.downloading(version: "0.7.0", fraction: 0.5).text == "0.7.0 を取得しています（50 %）")
        #expect(UpdateStatus.readyToInstall(version: "0.7.0", waiting: nil).menuItem == .installUpdate(version: "0.7.0"))
        #expect(UpdateStatus.manualRequired("x").menuItem == .updateNeedsManual)
        #expect(UpdateStatus.upToDate.menuItem == nil)
        let dto = UpdateStatusDTO(status: .readyToInstall(version: "0.7.0", waiting: "録音中です"), currentVersion: "0.6.0",
                                  enabled: true, lastCheckedAt: nil, lastInstall: nil)
        #expect(dto.state == "ready_to_install" && dto.version == "0.7.0" && dto.waiting == "録音中です")
    }

    @Test func menuShowsTheUpdateBeforeTheWindowItems() {
        let p = MenuBarPresentation.make(recorder: .idle(language: .ja), elapsedSeconds: nil, queue: .empty,
                                         readiness: .assumedReady, latestMinutesAvailable: false, rows: [],
                                         automationFailures: [], update: .installUpdate(version: "0.7.0"), now: Date())
        #expect(p.items.suffix(5) == [.installUpdate(version: "0.7.0"), .openWindow, .openLatestMinutes(enabled: false),
                                      .settings, .quit])
    }

    @Test func settingIsOnByDefaultAndReadsFalse() throws {
        #expect(Settings().autoUpdateEnabled)
        let s = try AutoNoteJSON.decoder().decode(Settings.self, from: Data(#"{"auto_update_enabled": false}"#.utf8))
        #expect(!s.autoUpdateEnabled)
        let old = try AutoNoteJSON.decoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(old.autoUpdateEnabled)
    }
}

/// Runs the real helper (`/bin/bash`, the script as written) against folders in a temporary directory.
@Suite struct UpdateHelperRunTests {
    struct Run {
        var status: Int32
        var result: UpdateInstallResult?
        var log: String
    }

    func run(target: URL, staged: URL, directory: URL) throws -> Run {
        var plan = UpdateInstallPlan(pid: 999_999, target: target, staged: staged, requirement: "never", directory: directory,
                                     fromVersion: "0.6.0", toVersion: "0.7.0", environment: [:])
        plan.launchCheckSeconds = 0
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appending(path: "install.sh")
        try Data(UpdateInstaller.script.utf8).write(to: script)
        let p = Process()
        p.executableURL = URL(filePath: "/bin/bash")
        p.arguments = [script.path] + plan.arguments
        p.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let result = (try? Data(contentsOf: plan.resultFile)).flatMap { try? JSONDecoder().decode(UpdateInstallResult.self, from: $0) }
        return Run(status: p.terminationStatus, result: result,
                   log: (try? String(contentsOf: plan.logFile, encoding: .utf8)) ?? "")
    }

    @Test func missingTargetIsReportedAsMoveAside() async throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = dir.appending(path: "u/0.7.0/unpacked/AutoNote.app")
        try writeApp(staged, bundleID: "com.yutaokoshi.autonote", version: "0.7.0")
        let r = try run(target: dir.appending(path: "missing/AutoNote.app"), staged: staged, directory: dir.appending(path: "u"))
        #expect(r.status == 1)
        #expect(r.result == UpdateInstallResult(from: "0.6.0", to: "0.7.0", result: .restored, reason: "move-aside"))
        #expect(FileManager.default.fileExists(atPath: staged.path))
        #expect(r.log.contains("開始: 0.6.0 → 0.7.0"))
        #expect(!r.log.contains("unbound variable"))
    }

    @Test func aStagedAppReplacedByALinkIsNotMovedIn() async throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appending(path: "Apps/AutoNote.app")
        try writeApp(target, bundleID: "com.yutaokoshi.autonote", version: "0.6.0")
        let elsewhere = dir.appending(path: "evil/AutoNote.app")
        try writeApp(elsewhere, bundleID: "com.yutaokoshi.autonote", version: "0.7.0")
        let staged = dir.appending(path: "u/0.7.0/unpacked/AutoNote.app")
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: elsewhere)
        let r = try run(target: target, staged: staged, directory: dir.appending(path: "u"))
        #expect(r.result?.reason == "staged")
        #expect(BundleFacts.read(target)?.shortVersion == "0.6.0")
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
        #expect(!FileManager.default.fileExists(atPath: UpdateInstallPlan.swapPath(for: target).path))
    }

    @Test func anUnsignedStagedAppFailsTheDeepCheckAndTheAppStays() async throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appending(path: "Apps/AutoNote.app")
        try writeApp(target, bundleID: "com.yutaokoshi.autonote", version: "0.6.0")
        let staged = dir.appending(path: "u/0.7.0/unpacked/AutoNote.app")
        try writeApp(staged, bundleID: "com.yutaokoshi.autonote", version: "0.7.0")
        let r = try run(target: target, staged: staged, directory: dir.appending(path: "u"))
        #expect(r.result?.reason == "verify")
        #expect(BundleFacts.read(target)?.shortVersion == "0.6.0")
        #expect(!FileManager.default.fileExists(atPath: UpdateInstallPlan.swapPath(for: target).path))
    }

    @Test func anInterruptedSwapIsRecoveredFirst() async throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        // An earlier helper stopped with the app moved aside (the old two-move design) — the app is missing.
        let target = dir.appending(path: "Apps/AutoNote.app")
        try writeApp(UpdateInstallPlan.legacyBackupPath(for: target), bundleID: "com.yutaokoshi.autonote", version: "0.6.0")
        let staged = dir.appending(path: "u/0.7.0/unpacked/AutoNote.app")
        try writeApp(staged, bundleID: "com.yutaokoshi.autonote", version: "0.7.0")
        let r = try run(target: target, staged: staged, directory: dir.appending(path: "u"))
        #expect(r.log.contains("から戻す"))
        #expect(BundleFacts.read(target)?.shortVersion == "0.6.0")
        #expect(!FileManager.default.fileExists(atPath: UpdateInstallPlan.legacyBackupPath(for: target).path))
    }

    @Test func aSecondHelperKeepsOut() async throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let updates = dir.appending(path: "u")
        let lock = updates.appending(path: "install.lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: lock.appending(path: "pid"))
        let target = dir.appending(path: "Apps/AutoNote.app")
        try writeApp(target, bundleID: "com.yutaokoshi.autonote", version: "0.6.0")
        let staged = updates.appending(path: "0.7.0/unpacked/AutoNote.app")
        try writeApp(staged, bundleID: "com.yutaokoshi.autonote", version: "0.7.0")
        let r = try run(target: target, staged: staged, directory: updates)
        #expect(r.status == 1 && r.result == nil)
        #expect(r.log.contains("別の補助"))
        #expect(FileManager.default.fileExists(atPath: staged.path))
        // The live helper's lock is left alone.
        #expect(FileManager.default.fileExists(atPath: lock.appending(path: "pid").path))
    }
}
