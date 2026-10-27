import Foundation
import Testing
import AutoNoteCore
import AutoNoteTestSupport

@Suite struct MenuBarPresentationTests {
    private let now = Samples.start
    private let meeting = MeetingID(rawValue: "20261024-1400-a1b2")
    private let start = MenuItem.startRecording(shortcut: KeyCombo(parsing: "ctrl+option+r"))
    private let stop = MenuItem.stop(shortcut: KeyCombo(parsing: "ctrl+option+r"))
    private let pause = MenuItem.pause(shortcut: KeyCombo(parsing: "ctrl+option+p"))
    private let folderMissing = Readiness(outputFolder: .init(path: "/Volumes/Vault", available: false), model: .installed("base"),
                                          claude: .init(path: "/usr/local/bin/claude", found: true))

    private func make(state: RecorderState, meetingID: MeetingID? = MeetingID(rawValue: "20261024-1400-a1b2"),
                      startedAt: Date? = nil, deadline: Date? = nil, deviceName: String? = nil,
                      elapsedSeconds: Int? = nil, queue: QueueStatus = .empty, readiness: Readiness = .assumedReady,
                      latestMinutesAvailable: Bool = true, rows: [MeetingRow] = [],
                      automationFailures: [AutomationRunRecord] = [], shortcuts: Shortcuts = Shortcuts()) -> MenuBarPresentation {
        let id: MeetingID? = state == .idle || state == .countdown ? nil : meetingID
        let snapshot = RecorderSnapshot(state: state, meetingID: id, startedAt: startedAt, deviceName: deviceName,
                                        deadline: deadline, language: .ja)
        return MenuBarPresentation.make(recorder: snapshot, elapsedSeconds: elapsedSeconds, queue: queue,
                                        readiness: readiness,
                                        latestMinutesAvailable: latestMinutesAvailable, rows: rows,
                                        automationFailures: automationFailures, shortcuts: shortcuts, now: now, timeZone: Samples.tokyo)
    }

    @Test func idle() {
        let p = make(state: .idle)
        #expect(p.symbol == "waveform" && p.title == nil)     // 計画 00 の E2E 7b はアイドル時の項目名 waveform を見る
        #expect(p.items.contains(start) && !p.items.contains(stop) && !p.items.contains(.cancelCountdown) && p.items.suffix(2) == [.settings, .quit])
        #expect(p.items == [start, .openWindow, .openLatestMinutes(enabled: true), .settings, .quit])
    }

    @Test func countdown() {
        // deadline now+3、deviceName "Jabra" → status line, .cancelCountdown and .startRecording
        let p = make(state: .countdown, deadline: now + 3, deviceName: "Jabra")
        #expect(p.symbol == "waveform" && p.title == nil)
        #expect(p.items.prefix(3) == [.status("Jabraが接続されました。3 秒後に録音を始めます"), start, .cancelCountdown])
        // The remaining seconds round up and never go below zero.
        #expect(make(state: .countdown, deadline: now + 2.2, deviceName: "Jabra").items.first == .status("Jabraが接続されました。3 秒後に録音を始めます"))
        #expect(make(state: .countdown, deadline: now - 5, deviceName: "Jabra").items.first == .status("Jabraが接続されました。0 秒後に録音を始めます"))
    }

    @Test func recording() {
        // elapsed 754 s (from RecorderPort.elapsed(), X25) → "12:34"; 3754 → "1:02:34"
        let p = make(state: .recording, startedAt: now - 754, elapsedSeconds: 754)
        #expect(p.symbol == "record.circle" && p.title == "12:34")
        #expect(p.items.prefix(4) == [stop, pause, .bookmark, .language(current: .ja)])
        #expect(!p.items.contains(start) && !p.items.contains(.cancelCountdown))
        #expect(make(state: .recording, startedAt: now - 3754, elapsedSeconds: 3754).title == "1:02:34")
        // Still starting (no meeting yet): "開始中…" and no timer.
        let starting = make(state: .recording, meetingID: nil, startedAt: now, elapsedSeconds: nil)
        #expect(starting.title == nil && starting.items.first == .status("開始中…"))
    }

    @Test func paused() {
        // symbol "pause.circle"、.resume あり、.pause なし、status "一時停止中"
        let p = make(state: .paused, startedAt: now - 100, elapsedSeconds: 65)
        #expect(p.symbol == "pause.circle" && p.title == "1:05")
        #expect(p.items.contains(.resume) && !p.items.contains(pause) && p.items.first == .status("一時停止中"))
        #expect(p.items.prefix(4) == [.status("一時停止中"), stop, .resume, .bookmark])
    }

    @Test func graceHasNoCancel() {   // 要件書 §5.9・§15.1（Task 1）
        let p = make(state: .grace, startedAt: now - 100, deadline: now + 12, elapsedSeconds: 100)
        #expect(p.items.contains(.status("機材が外れました。12 秒後に停止")) && !p.items.contains(.cancelCountdown) && p.items.contains(stop))
        #expect(p.symbol == "record.circle" && p.title == "1:40" && !p.items.contains(pause))
    }

    @Test func processingAndFolderAndFailures() {
        // idle + running transcribe 0.42 → hourglass and "文字起こし中 42%"
        let running = QueueItemDTO(meetingID: "m1", stage: "transcribe", state: "running", progress: 0.42, label: "文字起こし中 42%")
        let p = make(state: .idle, queue: QueueStatus(items: [running]))
        #expect(p.symbol == "hourglass" && p.items.contains(.status("文字起こし中 42%")))
        // Done items are hidden; failed / retry wait / overwrite wait get their own labels (X15).
        let others = [QueueItemDTO(meetingID: "d", stage: "", state: "done", label: "done"),
                      QueueItemDTO(meetingID: "f", stage: "summarize", state: "failed", label: "議事録生成中"),
                      QueueItemDTO(meetingID: "w", stage: "summarize", state: "waiting", label: "議事録生成中", notBefore: now + 60),
                      QueueItemDTO(meetingID: "o", stage: "write_vault", state: "waiting", label: "Vault に書き出し中", awaitingConfirmation: true)]
        let q = make(state: .idle, queue: QueueStatus(items: others))
        #expect(q.symbol == "waveform")
        #expect(q.items.filter { if case .status = $0 { true } else { false } } == [.status("失敗"), .status("再試行待ち"), .status("上書きの確認待ち")])
        // 保存先なし → ⚠ 項目（旧 .status("出力フォルダが見つかりません") は出さない）
        let missing = make(state: .idle, readiness: folderMissing).items
        #expect(missing.contains(.readinessIssue(.outputFolder, title: "⚠ 保存先が見つかりません — 設定を開く…")))
        #expect(!missing.contains(.status("出力フォルダが見つかりません")))
        // transcript_only の行 → minutesMissing、失敗記録 → automationFailed
        let row = MeetingRow(id: meeting.rawValue, title: "定例", startedAt: now, state: .transcriptOnly)
        let failure = AutomationRunRecord(name: "slack", event: .minutesGenerated, meetingID: meeting.rawValue, startedAt: now,
                                          durationSeconds: 1, exitCode: 1, timedOut: false, skippedReason: nil, logDirectory: "/tmp/x")
        let r = make(state: .idle, readiness: folderMissing, latestMinutesAvailable: false,
                     rows: [row, MeetingRow(id: "other", startedAt: now, state: .minutesGenerated)], automationFailures: [failure])
        #expect(r.items == [start,
                            .minutesMissing(meeting, label: "議事録 未生成: 10/24 14:00"),
                            .automationFailed(name: "slack", meetingID: meeting),
                            .readinessIssue(.outputFolder, title: "⚠ 保存先が見つかりません — 設定を開く…"),
                            .openWindow, .openLatestMinutes(enabled: false), .settings, .quit])
    }

    @Test func readinessIssuesInMenu() {
        let r = Readiness(outputFolder: .init(path: "/Volumes/Vault", available: false), model: .downloading("base", fraction: 0.4),
                          claude: .init(path: nil, found: false))
        let p = make(state: .idle, readiness: r, latestMinutesAvailable: false)
        #expect(Array(p.items.suffix(6)) == [.readinessIssue(.outputFolder, title: "⚠ 保存先が見つかりません — 設定を開く…"),
                                             .readinessIssue(.claude, title: "⚠ 議事録の作成に Claude Code が要ります…"),
                                             .openWindow, .openLatestMinutes(enabled: false), .settings, .quit])
        var empty = r; empty.outputFolder.path = ""
        #expect(make(state: .idle, readiness: empty).items.contains(.readinessIssue(.outputFolder, title: "⚠ 保存先を作れませんでした — 設定を開く…")))
    }

    @Test func readyHasNoIssueItems() {
        let ready = Readiness(outputFolder: .init(path: "/Users/u/Documents/AutoNote", available: true), model: .installed("base"),
                              claude: .init(path: "/usr/local/bin/claude", found: true))
        let items = make(state: .idle, readiness: ready).items
        #expect(!items.contains { if case .readinessIssue = $0 { true } else { false } })
        #expect(!items.contains(.status("出力フォルダが見つかりません")))
        // The model alone never makes a menu item.
        var noModel = ready; noModel.model = .none
        #expect(!make(state: .idle, readiness: noModel).items.contains { if case .readinessIssue = $0 { true } else { false } })
    }

    @Test func shortcutsFollowSettings() {
        var s = Shortcuts(); s.toggleRecording = "ctrl+shift+k"
        #expect(make(state: .idle, shortcuts: s).items.first == .startRecording(shortcut: KeyCombo(parsing: "ctrl+shift+k")))
        let rec = make(state: .recording, shortcuts: Shortcuts())
        #expect(rec.items.contains(.stop(shortcut: KeyCombo(parsing: "ctrl+option+r"))) && rec.items.contains(.pause(shortcut: KeyCombo(parsing: "ctrl+option+p"))))
        s.toggleRecording = "zzz"
        #expect(make(state: .idle, shortcuts: s).items.first == .startRecording(shortcut: nil))
    }
}
