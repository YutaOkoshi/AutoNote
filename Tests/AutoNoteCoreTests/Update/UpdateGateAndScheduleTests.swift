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
                window: Bool = false, user: Bool = false) -> UpdateInstallGate.Decision {
        UpdateInstallGate.decide(recorder: r, queue: queue, translationJobs: translation, mainWindowOpen: window,
                                 userRequested: user)
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
    func check(_ now: Date) { count += 1; last = now }
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
    @Test func backupSitsNextToTheAppAndArgumentsAreOrdered() {
        var plan = UpdateInstallPlan(
            pid: 42, target: URL(filePath: "/Applications/AutoNote.app"), staged: URL(filePath: "/tmp/u/0.7.0/unpacked/AutoNote.app"),
            requirement: #"identifier "x" and certificate leaf = H"ab""#, resultFile: URL(filePath: "/tmp/u/last-install.json"),
            logFile: URL(filePath: "/tmp/u/install.log"), fromVersion: "0.6.0", toVersion: "0.7.0",
            environment: ["AUTONOTE_UPDATE_FEED_URL": "http://x", "AUTONOTE_DATA_DIR": "/tmp/d"])
        #expect(plan.backup.path == "/Applications/.AutoNote-update-backup.app")
        plan.launchCheckSeconds = 3
        #expect(plan.arguments == ["42", "/Applications/AutoNote.app", "/tmp/u/0.7.0/unpacked/AutoNote.app",
                                   "/Applications/.AutoNote-update-backup.app", #"identifier "x" and certificate leaf = H"ab""#,
                                   "/tmp/u/last-install.json", "/tmp/u/install.log", "0.6.0", "0.7.0", "60", "3",
                                   "AUTONOTE_DATA_DIR=/tmp/d", "AUTONOTE_UPDATE_FEED_URL=http://x"])
    }

    @Test func onlyAutoNoteVariablesTravelToTheRelaunch() {
        let env = UpdateInstallPlan.relaunchEnvironment(["AUTONOTE_DATA_DIR": "/d", "HOME": "/Users/x", "GH_TOKEN": "t"])
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

/// Runs the real helper on a target that is not there: it must record `move-aside` and touch nothing else.
@Suite struct UpdateHelperRunTests {
    @Test func missingTargetIsReportedAsMoveAside() async throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = dir.appending(path: "staged/AutoNote.app")
        try writeApp(staged, bundleID: "com.yutaokoshi.autonote", version: "0.7.0")
        var plan = UpdateInstallPlan(
            pid: 999_999, target: dir.appending(path: "missing/AutoNote.app"), staged: staged, requirement: "never",
            resultFile: dir.appending(path: "last-install.json"), logFile: dir.appending(path: "install.log"),
            fromVersion: "0.6.0", toVersion: "0.7.0", environment: [:])
        plan.launchCheckSeconds = 0
        let script = dir.appending(path: "install.sh")
        try Data(UpdateInstaller.script.utf8).write(to: script)
        let p = Process()
        p.executableURL = URL(filePath: "/bin/bash")
        p.arguments = [script.path] + plan.arguments
        p.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 1)
        let result = try JSONDecoder().decode(UpdateInstallResult.self, from: Data(contentsOf: plan.resultFile))
        #expect(result == UpdateInstallResult(from: "0.6.0", to: "0.7.0", result: .restored, reason: "move-aside"))
        #expect(FileManager.default.fileExists(atPath: staged.path))
        let log = try String(contentsOf: plan.logFile, encoding: .utf8)
        #expect(log.contains("開始: 0.6.0 → 0.7.0"))
        #expect(!log.contains("unbound variable"))
    }
}
