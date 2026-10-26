import Foundation
import Testing
import AutoNoteTestSupport
@testable import AutoNoteCore

private let btRef = DeviceIdentity(raw: .fixtureBluetoothInput)!.deviceRef
private let mid = MeetingID(rawValue: "20261025-1000-abcd")

@Test func countdownCopy() {
    let n = UserNotice.deviceConnectedCountdown(btRef, seconds: 5)
    #expect(DeviceNoticeCopy.body(for: n) == "Fictional BT Headsetが接続されました。5 秒後に録音を始めます")
    #expect(DeviceNoticeCopy.actions(for: n).map(\.title) == ["取り消す"])
    #expect(DeviceNoticeCopy.actions(for: n).map(\.action) == [.cancelCountdown])
    #expect(DeviceNoticeCopy.isSticky(n) == false)
    #expect(n.id == "device.countdown")
}

@Test func firstSeenCopyAndActions() {
    let n = UserNotice.deviceSeenFirstTime(btRef)
    #expect(DeviceNoticeCopy.body(for: n) == "Fictional BT Headsetが接続されました。この機材で自動録音しますか？")
    let actions = DeviceNoticeCopy.actions(for: n)
    #expect(actions.map(\.title) == ["はい", "いいえ", "今後聞かない"])
    #expect(actions.map(\.action) == [.registerDevice(btRef, answer: .yes), .registerDevice(btRef, answer: .no), .registerDevice(btRef, answer: .never)])
    #expect(DeviceNoticeCopy.isSticky(n) == false)
    #expect(n.id == "device.first.00-11-22-33-44-55:input")
}

@Test func alreadyConnectedIsSticky() {
    let n = UserNotice.deviceAlreadyConnected(btRef)
    #expect(DeviceNoticeCopy.body(for: n) == "Fictional BT Headsetが接続されています。録音を始めますか？")
    #expect(DeviceNoticeCopy.actions(for: n).map(\.title) == ["開始"])
    #expect(DeviceNoticeCopy.actions(for: n).map(\.action) == [.startNow(btRef)])
    #expect(DeviceNoticeCopy.isSticky(n) == true)
    #expect(n.id == "device.connected.00-11-22-33-44-55:input")
    for other in [UserNotice.deviceConnectedCountdown(btRef, seconds: 5), .deviceSeenFirstTime(btRef), .deviceGoneGrace(btRef, seconds: 30), .outputFolderMissing, .diskLow(availableBytes: 1)] {
        #expect(DeviceNoticeCopy.isSticky(other) == false)
    }
}

@Test func graceCopyHasNoActions() {
    let n = UserNotice.deviceGoneGrace(btRef, seconds: 30)
    #expect(DeviceNoticeCopy.body(for: n) == "機材が外れました。30 秒後に停止")
    #expect(DeviceNoticeCopy.body(for: n) == Banner.grace(seconds: 30))
    #expect(DeviceNoticeCopy.actions(for: n).isEmpty)
    #expect(n.id == "device.grace")
}

private let nonDevice: [(UserNotice, String)] = [
    (.silence(.mic), "silence.mic"), (.silence(.system), "silence.system"),
    (.diskLow(availableBytes: 100), "disk.low"),
    (.recordingTooShort(mid), "meeting.tooShort.20261025-1000-abcd"),
    (.interruptedRecordingFound(mid), "meeting.interrupted.20261025-1000-abcd"),
    (.minutesGenerated(mid, title: "週次"), "meeting.minutes.20261025-1000-abcd"),
    (.transcriptOnly(mid), "meeting.transcriptOnly.20261025-1000-abcd"),
    (.claudeNotLoggedIn(mid), "meeting.claudeLogin.20261025-1000-abcd"),
    (.overwriteConfirmation(mid), "meeting.overwrite.20261025-1000-abcd"),
    (.outputFolderMissing, "output.missing"),
    (.automationFailed(name: "post", mid), "automation.post.20261025-1000-abcd"),
]

@Test(arguments: nonDevice.indices)
func nonDeviceNoticesHaveNoCopyHere(_ i: Int) {
    let (n, id) = nonDevice[i]
    #expect(DeviceNoticeCopy.body(for: n) == nil)
    #expect(DeviceNoticeCopy.actions(for: n).isEmpty)
    #expect(DeviceNoticeCopy.isSticky(n) == false)
    #expect(n.id == id)
}

@Test func bannersCopy() {
    #expect(Banner.grace(seconds: 30) == "機材が外れました。30 秒後に停止")
    #expect(Banner.micFallback == "機材に戻せなかったため、Mac の既定入力で録音を続けています")
    #expect(Banner.startFailed == "録音を開始できませんでした。マイクの許可と機材を確認してください")
}

@Test func canCancelOnlyInCountdown() {
    var s = RecorderSnapshot.idle(language: .ja)
    #expect(s.state == .idle); #expect(s.meetingID == nil); #expect(s.banner == nil); #expect(s.isManual == false)
    for state in [RecorderState.idle, .countdown, .recording, .paused, .grace] {
        s.state = state
        #expect(s.canCancelCountdown == (state == .countdown))
    }
}

@Test func snapshotRoundTripsThroughAutoNoteJSON() throws {
    let s = RecorderSnapshot(state: .grace, meetingID: mid, startedAt: Date(timeIntervalSince1970: 1_000), deviceName: "Fictional BT Headset",
                             deadline: Date(timeIntervalSince1970: 1_030), isManual: true, language: .ja, banner: Banner.grace(seconds: 30))
    let data = try AutoNoteJSON.compactEncoder().encode(s)
    let json = try #require(String(data: data, encoding: .utf8))
    for key in ["meeting_id", "started_at", "device_name", "is_manual"] { #expect(json.contains("\"\(key)\"")) }
    #expect(!json.contains("can_cancel_countdown"))
    #expect(try AutoNoteJSON.decoder().decode(RecorderSnapshot.self, from: data) == s)
}

@Test func fakeNotifierRecordsPostsAndWithdrawals() async {
    let fake = FakeUserNotifier()
    await fake.post(.outputFolderMissing); await fake.withdraw(id: "output.missing")
    #expect(await fake.posted == [.outputFolderMissing]); #expect(await fake.withdrawn == ["output.missing"])
}
