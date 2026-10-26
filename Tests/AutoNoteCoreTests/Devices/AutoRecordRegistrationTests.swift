import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

/// Registration prompts, the "already connected" notice and notice buttons (Task 9). Tests that need the device in
/// `monitor.connected()` drive it through `run()`; the rest call the coordinator directly.
@Suite(.timeLimit(.minutes(1))) struct AutoRecordRegistrationTests {
    private func countdowns(_ h: CoordinatorHarness) async -> [UserNotice] {
        await h.notifier.posted.filter { if case .deviceConnectedCountdown = $0 { true } else { false } }
    }

    private func firstSeen(_ h: CoordinatorHarness) async -> [UserNotice] {
        await h.notifier.posted.filter { if case .deviceSeenFirstTime = $0 { true } else { false } }
    }

    @Test func firstSeenAddedAsksRegistration() async throws {
        let h = try await CoordinatorHarness()
        await h.coordinator.handle(.added(h.U))
        #expect(await h.notifier.posted.last == .deviceSeenFirstTime(h.U.deviceRef))
        #expect(await countdowns(h).isEmpty)
        #expect(await h.coordinator.current().state == .idle)
    }

    @Test func answerYesRegistersAndStartsCountdown() async throws {
        let h = try await CoordinatorHarness()
        let U = h.U
        try await h.startRunning()
        try await h.connectAndSettle(CoordinatorHarness.rawU)
        await h.coordinator.handle(.registerDevice(U.deviceRef, answer: .yes))
        let entry = try #require(await h.registry.entries().first { $0.deviceUID == U.deviceUID })
        #expect(entry.registeredOn == FakeMacIdentity().identity)
        #expect(entry.disposition == .registered)
        #expect(await h.notifier.posted.contains(.deviceConnectedCountdown(U.deviceRef, seconds: 5)))
        #expect(await h.notifier.withdrawn.contains(UserNotice.deviceSeenFirstTime(U.deviceRef).id))
        #expect(await h.coordinator.current().state == .countdown)
        await h.stopRunning()
    }

    @Test func answerYesWhileRecordingRegistersOnly() async throws {
        let h = try await CoordinatorHarness()
        let U = h.U
        try await h.startRunning()
        await h.startAutoRecording()
        try await h.connectAndSettle(CoordinatorHarness.rawU)
        #expect(await h.notifier.posted.last == .deviceSeenFirstTime(U.deviceRef))
        await h.coordinator.handle(.registerDevice(U.deviceRef, answer: .yes))
        #expect(await h.registry.match(U) == .registered(
            entryID: try #require(await h.registry.entries().first { $0.deviceUID == U.deviceUID }?.id), rule: .deviceUID))
        #expect(await countdowns(h) == [.deviceConnectedCountdown(h.A.deviceRef, seconds: 5)])
        #expect(await h.recorder.starts.count == 1)
        #expect(await h.coordinator.current().state == .recording)
        await h.stopRunning()
    }

    /// Not in the brief's list: `.yes` after the device was unplugged registers it and touches nothing else.
    @Test func answerYesAfterUnplugRegistersOnly() async throws {
        let h = try await CoordinatorHarness()
        let U = h.U
        await h.coordinator.handle(.added(U))
        await h.coordinator.handle(.removed(U))
        await h.coordinator.handle(.registerDevice(U.deviceRef, answer: .yes))
        #expect(await h.registry.entries().contains { $0.deviceUID == U.deviceUID && $0.disposition == .registered })
        #expect(await countdowns(h).isEmpty)
        #expect(await h.coordinator.current().state == .idle)
    }

    @Test func answerNoAsksAgainNextConnection() async throws {
        let h = try await CoordinatorHarness(registered: [])
        let c = h.coordinator, U = h.U
        await c.handle(.added(U))
        await c.handle(.registerDevice(U.deviceRef, answer: .no))
        #expect(await h.registry.entries().isEmpty)
        #expect(await h.notifier.withdrawn.contains(UserNotice.deviceSeenFirstTime(U.deviceRef).id))
        await c.handle(.removed(U))
        await c.handle(.added(U))
        #expect(await firstSeen(h) == [.deviceSeenFirstTime(U.deviceRef), .deviceSeenFirstTime(U.deviceRef)])
    }

    @Test func answerNeverIgnoresSilently() async throws {
        let h = try await CoordinatorHarness()
        let c = h.coordinator, U = h.U
        await c.handle(.added(U))
        await c.handle(.registerDevice(U.deviceRef, answer: .never))
        let entry = try #require(await h.registry.entries().first { $0.deviceUID == U.deviceUID })
        #expect(await h.registry.match(U) == .ignored(entryID: entry.id))
        #expect(await h.notifier.withdrawn.contains(UserNotice.deviceSeenFirstTime(U.deviceRef).id))
        let postedBefore = await h.notifier.posted
        await c.handle(.removed(U))
        await c.handle(.added(U))
        #expect(await h.notifier.posted == postedBefore)
        #expect(await c.current().state == .idle)
    }

    @Test func launchPresentPostsAlreadyConnected() async throws {
        let h = try await CoordinatorHarness()
        await h.coordinator.handle(.present(h.A, .launch))
        #expect(await h.notifier.posted == [.deviceAlreadyConnected(h.A.deviceRef)])
        #expect(await h.recorder.starts.isEmpty)
        #expect(h.timer.pendingCount == 0)
        #expect(await h.coordinator.current().state == .idle)
    }

    @Test func unregisteredPresentPostsNothing() async throws {
        let h = try await CoordinatorHarness()
        await h.coordinator.handle(.present(CoordinatorHarness.builtInMicrophone, .launch))
        await h.coordinator.handle(.present(h.U, .launch))
        #expect(await h.notifier.posted.isEmpty)
    }

    @Test func wakePresentPostsAlreadyConnected() async throws {
        let h = try await CoordinatorHarness()
        await h.coordinator.handle(.present(h.A, .wake))
        #expect(await h.notifier.posted == [.deviceAlreadyConnected(h.A.deviceRef)])
        #expect(await h.recorder.starts.isEmpty)
        #expect(h.timer.pendingCount == 0)
    }

    /// Y5: `.present` while not idle posts nothing.
    @Test func presentWhileRecordingPostsNothing() async throws {
        let h = try await CoordinatorHarness()
        try await h.coordinator.manualStart(language: nil)
        await h.coordinator.handle(.present(h.A, .wake))
        #expect(await h.notifier.posted.isEmpty)
    }

    @Test func startNowRecordsAutoWithoutCountdown() async throws {
        let h = try await CoordinatorHarness()
        let c = h.coordinator, A = h.A
        try await h.startRunning(initial: [.fixtureBluetoothInput])
        #expect(await h.notifier.posted == [.deviceAlreadyConnected(A.deviceRef)])
        await c.handle(.startNow(A.deviceRef))
        let starts = await h.recorder.starts
        #expect(starts.count == 1)
        #expect(starts.first?.0 == A.deviceRef && starts.first?.1 == .ja && starts.first?.2 == false)
        #expect(await countdowns(h).isEmpty)
        #expect(await h.notifier.withdrawn.contains(UserNotice.deviceAlreadyConnected(A.deviceRef).id))
        try await h.disconnectAndSettle(.fixtureBluetoothInput)
        #expect(await c.current().state == .grace)
        await h.stopRunning()
    }

    @Test func startNowForDisconnectedDeviceDoesNothing() async throws {
        let h = try await CoordinatorHarness()
        await h.coordinator.handle(.startNow(h.A.deviceRef))
        #expect(await h.recorder.starts.isEmpty)
        #expect(await h.coordinator.current().state == .idle)
    }

    @Test func cancelCountdownActionCancels() async throws {
        let h = try await CoordinatorHarness()
        await h.coordinator.handle(.added(h.A))
        #expect(await h.coordinator.current().state == .countdown)
        await h.coordinator.handle(.cancelCountdown)
        #expect(await h.coordinator.current().state == .idle)
        await h.timer.advance(by: 5)
        #expect(await h.recorder.starts.isEmpty)
    }

    @Test func unrelatedActionsAreIgnored() async throws {
        let h = try await CoordinatorHarness()
        let c = h.coordinator
        await c.handle(.added(h.A))
        let before = await c.current()
        let postedBefore = await h.notifier.posted
        await c.handle(.openMeeting(MeetingID(rawValue: "fictional-meeting")))
        #expect(await c.current() == before)
        #expect(await h.notifier.posted == postedBefore)
        #expect(await h.recorder.starts.isEmpty)
    }

    @Test func alreadyConnectedWithdrawnOnRemoval() async throws {
        let h = try await CoordinatorHarness()
        let A = h.A
        await h.coordinator.handle(.present(A, .launch))
        await h.coordinator.handle(.removed(A))
        #expect(await h.notifier.withdrawn.contains("device.connected.\(A.deviceUID)"))
    }

    @Test func alreadyConnectedWithdrawnWhenRecordingStarts() async throws {
        let h = try await CoordinatorHarness()
        let A = h.A
        await h.coordinator.handle(.present(A, .launch))
        try await h.coordinator.manualStart(language: nil)
        #expect(await h.notifier.withdrawn.contains("device.connected.\(A.deviceUID)"))
    }

    @Test func otherMacDeviceAsksReRegistration() async throws {
        let h = try await CoordinatorHarness(registered: [], registeredOnOtherMac: [CoordinatorHarness.otherMacHeadset])
        let A = h.A
        await h.registry.reload()
        #expect(await h.registry.match(A) == .reRegistrationSuggested(
            entryID: try #require(await h.registry.entries().first?.id)))
        try await h.startRunning()
        try await h.connectAndSettle(.fixtureBluetoothInput)
        #expect(await h.notifier.posted.last == .deviceSeenFirstTime(A.deviceRef))
        await h.coordinator.handle(.registerDevice(A.deviceRef, answer: .yes))
        let entries = await h.registry.entries()
        #expect(entries.count == 2)
        #expect(entries.contains { $0.deviceUID == A.deviceUID && $0.registeredOn == FakeMacIdentity().identity })
        #expect(await h.notifier.posted.contains(.deviceConnectedCountdown(A.deviceRef, seconds: 5)))
        await h.stopRunning()
    }
}
