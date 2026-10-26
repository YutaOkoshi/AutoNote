import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct SilenceMonitorTests {
    private func t(_ s: Double) -> TimelineTime { TimelineTime(seconds: s) }

    @Test func micWarnsAt15sWhenSilent() {
        var m = SilenceMonitor(start: t(0))
        m.observe(.mic, chunk: AudioFixtures.zeros(start: 0, seconds: 15))
        #expect(m.tick(now: t(14.9), paused: false).isEmpty)
        #expect(m.tick(now: t(15), paused: false) == [.init(track: .mic, message: SilenceMonitor.micMessage)])
        #expect(m.tick(now: t(30), paused: false).isEmpty)
    }

    @Test func micWarnsWhenNoChunksAtAll() {
        var m = SilenceMonitor(start: t(0))
        #expect(m.tick(now: t(15), paused: false) == [.init(track: .mic, message: SilenceMonitor.micMessage)])
    }

    @Test func micDoesNotWarnWithSignal() {
        var m = SilenceMonitor(start: t(0))
        m.observe(.mic, chunk: AudioFixtures.tone(start: 0, seconds: 1))
        #expect(m.tick(now: t(15), paused: false).isEmpty)
        #expect(m.tick(now: t(30), paused: false).isEmpty)
    }

    @Test func systemWarns60sAfterLastCallback() {
        var m = SilenceMonitor(start: t(0))
        m.observe(.mic, chunk: AudioFixtures.tone(start: 0, seconds: 1))
        #expect(m.tick(now: t(1), paused: false).isEmpty)
        m.observe(.system, chunk: AudioFixtures.tone(start: 0, seconds: 1, track: .system))
        #expect(m.tick(now: t(60.9), paused: false).isEmpty)
        #expect(m.tick(now: t(61), paused: false) == [.init(track: .system, message: SilenceMonitor.systemMessage)])
        #expect(m.tick(now: t(120), paused: false).isEmpty)
    }

    @Test func allZeroSystemChunkDoesNotCountAsReceived() {
        var m = SilenceMonitor(start: t(0))
        m.observe(.mic, chunk: AudioFixtures.tone(start: 0, seconds: 1))
        for s in stride(from: 0.0, to: 59.0, by: 1.0) {
            m.observe(.system, chunk: AudioFixtures.zeros(start: s, seconds: 1, track: .system))
            #expect(m.tick(now: t(s + 1), paused: false).isEmpty)
        }
        m.observe(.system, chunk: AudioFixtures.zeros(start: 59, seconds: 1, track: .system))
        #expect(m.tick(now: t(60), paused: false) == [.init(track: .system, message: SilenceMonitor.systemMessage)])
    }

    @Test func pausedTimeIsNotCountedForMic() {
        var m = SilenceMonitor(start: t(0))
        #expect(m.tick(now: t(10), paused: false).isEmpty)
        #expect(m.tick(now: t(100), paused: true).isEmpty)
        #expect(m.tick(now: t(104), paused: false).isEmpty)       // 14 s recorded
        #expect(m.tick(now: t(105), paused: false) == [.init(track: .mic, message: SilenceMonitor.micMessage)])
    }

    @Test func pausedTimeIsNotCountedForSystemAndBothWarnInOrder() {
        var m = SilenceMonitor(start: t(0))
        m.observe(.mic, chunk: AudioFixtures.tone(start: 0, seconds: 1))
        #expect(m.tick(now: t(10), paused: false).isEmpty)
        #expect(m.tick(now: t(100), paused: true).isEmpty)
        #expect(m.tick(now: t(149), paused: false).isEmpty)       // 59 s recorded
        #expect(m.tick(now: t(150), paused: false) == [.init(track: .system, message: SilenceMonitor.systemMessage)])

        var both = SilenceMonitor(start: t(0))
        #expect(both.tick(now: t(14), paused: false).isEmpty)
        #expect(both.tick(now: t(60), paused: false) == [
            .init(track: .mic, message: SilenceMonitor.micMessage),
            .init(track: .system, message: SilenceMonitor.systemMessage),
        ])
    }

    @Test func messagesMatchSpec() {
        #expect(SilenceMonitor.micMessage == "マイクが無音です。機材と許可を確認してください")
        #expect(SilenceMonitor.systemMessage == "システム音声が届いていません。システム音声の録音許可と、会議アプリの音が出ているかを確認してください")
    }
}
