import Foundation

public enum MenuItem: Equatable, Sendable {
    case status(String), startRecording(shortcut: KeyCombo?), stop(shortcut: KeyCombo?), pause(shortcut: KeyCombo?), resume, bookmark, cancelCountdown, language(current: Language), openWindow
    case openLatestMinutes(enabled: Bool), minutesMissing(MeetingID, label: String), automationFailed(name: String, meetingID: MeetingID)
    /// A readiness problem that blocks minutes; choosing it opens the place to fix it.
    case readinessIssue(ReadinessRow.Item, title: String)
    case settings, quit
}

/// What the menu bar shows for one moment. Pure: the caller passes every input, including `now`.
public struct MenuBarPresentation: Equatable, Sendable {
    public var symbol: String
    /// The elapsed time next to the symbol; only while recording, paused or in the grace period.
    public var title: String?
    public var items: [MenuItem]

    public init(symbol: String, title: String?, items: [MenuItem]) {
        self.symbol = symbol
        self.title = title
        self.items = items
    }

    /// - Parameter elapsedSeconds: the meeting timeline position from `RecorderPort.elapsed()` (ruling X25); it keeps
    ///   counting while paused (§5.4).
    public static func make(recorder: RecorderSnapshot, elapsedSeconds: Int?, queue: QueueStatus, readiness: Readiness,
                            latestMinutesAvailable: Bool, rows: [MeetingRow], automationFailures: [AutomationRunRecord],
                            shortcuts: Shortcuts = Shortcuts(), now: Date, timeZone: TimeZone = .current) -> MenuBarPresentation {
        var items: [MenuItem] = []
        let starting = recorder.state == .recording && recorder.meetingID == nil
        if let line = statusLine(recorder, now: now) { items.append(.status(line)) }

        let bindings = ShortcutBindings(shortcuts)
        let toggle = bindings.combo(for: .toggleRecording), pause = bindings.combo(for: .togglePause)
        switch recorder.state {
        case .idle, .countdown: items.append(.startRecording(shortcut: toggle))
        case .recording: items += [.stop(shortcut: toggle), .pause(shortcut: pause), .bookmark]
        case .paused: items += [.stop(shortcut: toggle), .resume, .bookmark]
        case .grace: items += [.stop(shortcut: toggle), .bookmark]
        }
        if recorder.canCancelCountdown { items.append(.cancelCountdown) }
        if [.recording, .paused, .grace].contains(recorder.state) { items.append(.language(current: recorder.language)) }

        items += queue.items.compactMap(queueLine).map(MenuItem.status)
        items += rows.filter { $0.state == .transcriptOnly }.map {
            .minutesMissing(MeetingID(rawValue: $0.id), label: "議事録 未生成: \(shortDate($0.startedAt, timeZone: timeZone))")
        }
        items += automationFailures.map { .automationFailed(name: $0.name, meetingID: MeetingID(rawValue: $0.meetingID)) }
        items += readinessIssues(readiness)
        items += [.openWindow, .openLatestMinutes(enabled: latestMinutesAvailable), .settings, .quit]

        let title: String? = switch recorder.state {
        case .recording, .paused, .grace: starting ? nil : elapsedSeconds.map(clock)
        case .idle, .countdown: nil
        }
        return MenuBarPresentation(symbol: symbol(recorder.state, queue: queue), title: title, items: items)
    }

    /// ⚠ items for what stops minutes: the output folder first, then Claude Code. The model never makes one, since
    /// Apple speech recognition stands in while whisper is missing.
    public static func readinessIssues(_ r: Readiness) -> [MenuItem] {
        var items: [MenuItem] = []
        if !r.outputFolder.available {
            items.append(.readinessIssue(.outputFolder, title: r.outputFolder.path.isEmpty
                ? "⚠ 保存先を作れませんでした — 設定を開く…" : "⚠ 保存先が見つかりません — 設定を開く…"))
        }
        if !r.claude.found { items.append(.readinessIssue(.claude, title: "⚠ 議事録の作成に Claude Code が要ります…")) }
        return items
    }

    /// The queue line for one job, or nil for a finished job (ruling X15).
    public static func queueLine(_ item: QueueItemDTO) -> String? {
        if item.state == JobState.done.rawValue { return nil }
        if item.state == JobState.failed.rawValue { return "失敗" }
        if item.notBefore != nil { return "再試行待ち" }
        if item.awaitingConfirmation { return "上書きの確認待ち" }
        return item.label.isEmpty ? MeetingListBuilder.waitingLabel : item.label
    }

    /// Seconds left until `deadline`, rounded up, never below zero.
    public static func secondsRemaining(_ deadline: Date?, now: Date) -> Int {
        guard let deadline else { return 0 }
        return max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }

    /// `m:ss` under an hour, `h:mm:ss` from an hour.
    public static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func statusLine(_ r: RecorderSnapshot, now: Date) -> String? {
        switch r.state {
        case .idle: nil
        case .countdown: "\(r.deviceName ?? "機材")が接続されました。\(secondsRemaining(r.deadline, now: now)) 秒後に録音を始めます"
        case .recording: r.meetingID == nil ? "開始中…" : nil
        case .paused: "一時停止中"
        case .grace: Banner.grace(seconds: secondsRemaining(r.deadline, now: now))
        }
    }

    private static func symbol(_ state: RecorderState, queue: QueueStatus) -> String {
        switch state {
        case .idle: queue.items.contains { $0.state == JobState.running.rawValue } ? "hourglass" : "waveform"
        case .countdown: "waveform"
        case .recording, .grace: "record.circle"
        case .paused: "pause.circle"
        }
    }

    private static func shortDate(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "MM/dd HH:mm"
        return f.string(from: date)
    }
}
