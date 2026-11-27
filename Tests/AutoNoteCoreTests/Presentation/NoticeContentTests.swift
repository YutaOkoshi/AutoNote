import Foundation
import Testing
import AutoNoteCore

@Suite struct NoticeContentTests {
    static let dev = DeviceRef(name: "Jabra", uid: "uid-1", transport: "usb")
    static let mid = MeetingID(rawValue: "m-1")

    /// One notice per case with the expected body, buttons and actions from the brief's table.
    static let table: [(UserNotice, String, [(String, UserNoticeAction)])] = [
        (.deviceConnectedCountdown(dev, seconds: 5), DeviceNoticeCopy.body(for: .deviceConnectedCountdown(dev, seconds: 5))!, [("取り消す", .cancelCountdown)]),
        (.deviceSeenFirstTime(dev), DeviceNoticeCopy.body(for: .deviceSeenFirstTime(dev))!,
         [("はい", .registerDevice(dev, answer: .yes)), ("いいえ", .registerDevice(dev, answer: .no)), ("今後聞かない", .registerDevice(dev, answer: .never))]),
        (.deviceAlreadyConnected(dev), DeviceNoticeCopy.body(for: .deviceAlreadyConnected(dev))!, [("開始", .startNow(dev))]),
        (.deviceGoneGrace(dev, seconds: 10), DeviceNoticeCopy.body(for: .deviceGoneGrace(dev, seconds: 10))!, []),
        (.silence(.mic), SilenceMonitor.micMessage, [("システム設定を開く", .openPrivacySettings)]),
        (.silence(.system), SilenceMonitor.systemMessage, [("システム設定を開く", .openPrivacySettings)]),
        (.diskLow(availableBytes: 900_000_000), "ディスクの空きが 1GB を切りました（残り 858 MB）。500MB を切ると録音を止めます", []),
        (.recordingTooShort(mid), "1 分未満の短すぎる録音です。文字起こししますか？", [("文字起こしする", .transcribeTooShort(mid)), ("破棄", .discardTooShort(mid))]),
        (.interruptedRecordingFound(mid), "前回の録音が途中で終わっています。文字起こしと議事録を作りますか？", [("はい", .recoverInterrupted(mid)), ("破棄", .discardInterrupted(mid))]),
        (.minutesGenerated(mid, title: "定例"), "議事録ができました: 定例", [("開く", .openMeeting(mid))]),
        (.transcriptOnly(mid), "議事録 未生成: 文字起こしだけを書き出しました", [("再実行", .retry(mid))]),
        (.claudeNotLoggedIn(mid), "議事録 未生成: Claude Code にログインしていません。ターミナルで claude を起動してログインしてから再実行してください", [("再実行", .retry(mid))]),
        (.overwriteConfirmation(mid), "Vault の会議ファイルがアプリの外で編集されています。上書きしますか？",
         [("上書きする", .resolveOverwrite(mid, overwrite: true)), ("残す", .resolveOverwrite(mid, overwrite: false))]),
        (.outputFolderMissing, "保存先が見つかりません", []),
        (.automationFailed(name: "weekly", mid), "Automation 失敗: weekly", [("開く", .openMeeting(mid))]),
        (.recordingLoss(.system, reason: .notArriving),
         "システム音声が 1 分以上録音に入っていません（ほかのアプリは音を出しています）。相手が話しているのにこの通知が出たときは、録音を止めて始め直してください。相手が黙っている・ミュート中なら問題ありません", []),
        (.recordingLoss(.system, reason: .sourceFailed),
         "システム音声を録音できていません。この先の相手の声は録音に入りません。システム音声の録音許可とディスクの空きを確認し、録音を止めて始め直してください",
         [("システム設定を開く", .openPrivacySettings)]),
        (.recordingLoss(.mic, reason: .sourceFailed),
         "マイクを録音できていません。この先の自分の声は録音に入りません。マイクの許可と機材、ディスクの空きを確認し、録音を止めて始め直してください",
         [("システム設定を開く", .openPrivacySettings)]),
    ]

    // The four device cases take body and buttons straight from DeviceNoticeCopy.
    @Test func deviceCasesUseDeviceNoticeCopy() {
        for n in Self.table.prefix(4).map(\.0) {
            let c = NoticeContent.make(n)
            #expect(c.body == DeviceNoticeCopy.body(for: n))
            #expect(c.buttons.map(\.title) == DeviceNoticeCopy.actions(for: n).map(\.title))
            for (b, a) in zip(c.buttons, DeviceNoticeCopy.actions(for: n)) {
                #expect(NoticeContent.action(category: c.category, buttonID: b.id, userInfo: c.userInfo) == a.action)
            }
        }
    }

    // The remaining 10 rows have the table body, title "AutoNote" and the table button titles.
    @Test func everyOtherCaseHasTableText() {
        for (n, body, buttons) in Self.table.dropFirst(4) {
            let c = NoticeContent.make(n)
            #expect(c.body == body)
            #expect(c.title == "AutoNote")
            #expect(c.buttons.map(\.title) == buttons.map(\.0))
        }
    }

    // All 15 cases (18 notices, 16 categories: a recording loss has one per reason) round-trip each button through
    // action(category:buttonID:userInfo:) to the table's action.
    @Test func buttonsMapBackToActions() {
        #expect(Self.table.count == 18)  // 15 cases, silence in both tracks, recording loss in three forms
        for (n, _, buttons) in Self.table {
            let c = NoticeContent.make(n)
            #expect(Set(c.buttons.map(\.id)).count == c.buttons.count)
            for (b, expected) in zip(c.buttons, buttons) {
                #expect(NoticeContent.action(category: c.category, buttonID: b.id, userInfo: c.userInfo) == expected.1)
            }
        }
        #expect(Set(Self.table.map { NoticeContent.make($0.0).category }).count == 16)
    }

    /// A system notification gets its buttons from its category, and a category is registered from one sample:
    /// every notice must have exactly the buttons of its category's sample.
    @Test func everyNoticeHasTheButtonsItsCategoryIsRegisteredWith() throws {
        let samples = NoticeContent.categorySamples.map(NoticeContent.make)
        #expect(samples.map(\.category).sorted() == NoticeContent.allCategories.sorted())
        for (n, _, _) in Self.table + [(.recordingLoss(.mic, reason: .notArriving), "", [])] {
            let c = NoticeContent.make(n)
            let sample = try #require(samples.first { $0.category == c.category })
            #expect(sample.buttons == c.buttons, "\(c.category)")
        }
    }

    // The content id is the UserNotice id so a re-post replaces and withdraw finds it.
    @Test func idIsUserNoticeID() {
        for (n, _, _) in Self.table { #expect(NoticeContent.make(n).id == n.id) }
    }

    // Tapping the notification body opens the meeting when it has one, otherwise nothing specific.
    @Test func tapWithoutButton() {
        let c = NoticeContent.make(.minutesGenerated(Self.mid, title: "定例"))
        #expect(NoticeContent.action(category: c.category, buttonID: nil, userInfo: c.userInfo) == .openMeeting(Self.mid))
        let o = NoticeContent.make(.outputFolderMissing)
        #expect(NoticeContent.action(category: o.category, buttonID: nil, userInfo: o.userInfo) == nil)
    }

    // Silence and disk events become notices; bookmarks and stops do not.
    @Test func relayRecordingEvents() {
        #expect(NoticeRelay.notices(for: .silenceWarning(SilenceWarning(track: .mic, message: SilenceMonitor.micMessage))) == [.silence(.mic)])
        #expect(NoticeRelay.notices(for: .diskSpaceLow(availableBytes: 900_000_000)) == [.diskLow(availableBytes: 900_000_000)])
        let b = Bookmark(at: TimelineTime(seconds: 1))
        let m = Manifest(id: Self.mid, title: nil, startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, source: .live, device: nil, language: .ja, tracks: [], pauses: [], bookmarks: [], status: .recorded, silenceWarning: false, autonoteVersion: "test")
        #expect(NoticeRelay.notices(for: .bookmarked(b)).isEmpty && NoticeRelay.notices(for: .stopped(m, .manual)).isEmpty)
    }

    /// One notice about system audio at a time: the specific one (another app plays, yet nothing arrives) takes the
    /// place of the general silence warning, and is taken back once audio is heard again.
    @Test func relayTakesNoticesBack() {
        #expect(NoticeRelay.withdrawals(for: .audioNotArriving(.system, seconds: 61)) == [UserNotice.silence(.system).id])
        #expect(NoticeRelay.withdrawals(for: .audioArrivingAgain(.system)) == [UserNotice.recordingLoss(.system, reason: .notArriving).id])
        #expect(NoticeRelay.withdrawals(for: .sourceFailed(.system, message: "gave up")).isEmpty)
        #expect(NoticeRelay.withdrawals(for: .diskSpaceLow(availableBytes: 1)).isEmpty)
    }

    // A track that failed, or audio that keeps not arriving, is told while the recording still runs.
    @Test func relayLostAudio() {
        #expect(NoticeRelay.notices(for: .sourceFailed(.system, message: "gave up")) == [.recordingLoss(.system, reason: .sourceFailed)])
        #expect(NoticeRelay.notices(for: .sourceFailed(.mic, message: "denied")) == [.recordingLoss(.mic, reason: .sourceFailed)])
        #expect(NoticeRelay.notices(for: .audioNotArriving(.system, seconds: 61)) == [.recordingLoss(.system, reason: .notArriving)])
        #expect(NoticeRelay.notices(for: .audioArrivingAgain(.system)).isEmpty)
        for reason in [RecordingLossReason.notArriving, .sourceFailed] {
            #expect(NoticeContent.needsAttention(category: NoticeContent.make(.recordingLoss(.system, reason: reason)).category))
        }
        // The settings button opens the pane of the track.
        #expect(NoticeContent.make(.recordingLoss(.system, reason: .sourceFailed)).userInfo["track"] == "system")
        #expect(NoticeContent.make(.recordingLoss(.mic, reason: .sourceFailed)).userInfo["track"] == "mic")
    }

    static func item(_ id: String, failure: String? = nil, confirm: Bool = false, state: String = "running") -> QueueItemDTO {
        QueueItemDTO(meetingID: id, state: state, awaitingConfirmation: confirm, summaryFailure: failure)
    }

    // A job present before and gone now yields minutes / transcript-only by its row state; no row or other state yields nothing.
    @Test func relayCompletedJobs() {
        let rows = [MeetingRow(id: "a", title: "定例", state: .minutesGenerated), MeetingRow(id: "b", state: .transcriptOnly), MeetingRow(id: "c", state: .failed)]
        let prev = QueueStatus(items: [Self.item("a"), Self.item("b"), Self.item("c"), Self.item("z")])
        let got = NoticeRelay.notices(previous: prev, current: .empty, rows: rows)
        #expect(got == [.minutesGenerated(MeetingID(rawValue: "a"), title: "定例"), .transcriptOnly(MeetingID(rawValue: "b"))])
        // A job that is still in current (even done) is not "disappeared".
        #expect(NoticeRelay.notices(previous: prev, current: prev, rows: rows).isEmpty)
    }

    // A newly seen summaryFailure maps not_logged_in to the login notice and anything else to transcript-only; unchanged yields nothing.
    @Test func relaySummaryFailure() {
        let none = QueueStatus(items: [Self.item("a")])
        let login = QueueStatus(items: [Self.item("a", failure: "not_logged_in")])
        let rate = QueueStatus(items: [Self.item("a", failure: "rate_limited")])
        let a = MeetingID(rawValue: "a")
        #expect(NoticeRelay.notices(previous: none, current: login, rows: []) == [.claudeNotLoggedIn(a)])
        #expect(NoticeRelay.notices(previous: none, current: rate, rows: []) == [.transcriptOnly(a)])
        #expect(NoticeRelay.notices(previous: login, current: login, rows: []).isEmpty)
        // A job new in current that already carries a failure counts as newly having it.
        #expect(NoticeRelay.notices(previous: .empty, current: login, rows: []) == [.claudeNotLoggedIn(a)])
    }

    // Overwrite confirmation fires on false to true only; the folder notice only on available to missing.
    @Test func relayOverwriteAndFolder() {
        let off = QueueStatus(items: [Self.item("a")])
        let on = QueueStatus(items: [Self.item("a", confirm: true)])
        #expect(NoticeRelay.notices(previous: off, current: on, rows: []) == [.overwriteConfirmation(MeetingID(rawValue: "a"))])
        #expect(NoticeRelay.notices(previous: on, current: on, rows: []).isEmpty)
        #expect(NoticeRelay.notices(outputFolderWasAvailable: true, isAvailable: false) == [.outputFolderMissing])
        #expect(NoticeRelay.notices(outputFolderWasAvailable: false, isAvailable: false).isEmpty)
        #expect(NoticeRelay.notices(outputFolderWasAvailable: true, isAvailable: true).isEmpty)
        #expect(NoticeRelay.notices(outputFolderWasAvailable: false, isAvailable: true).isEmpty)
    }
}
