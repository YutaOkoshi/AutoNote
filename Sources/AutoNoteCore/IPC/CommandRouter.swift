import Foundation

/// Maps each socket request onto the app's ports. Not on the MainActor: it runs on connection tasks.
public struct CommandRouter: IPCHandler {
    private let ports: AppPorts
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(ports: AppPorts, now: @Sendable @escaping () -> Date = { Date() }, calendar: Calendar = .current) {
        self.ports = ports
        self.now = now
        self.calendar = calendar
    }

    public func handle(_ request: IPCRequest) async -> IPCResponse {
        do {
            return .success(request.id, try await run(request))
        } catch {
            return .failure(request.id, Self.ipcError(error))
        }
    }

    /// The one wording for command errors, shared by the CLI and the UI.
    public static func ipcError(_ e: Error) -> IPCError {
        guard let e = e as? AppCommandError else { return IPCError(code: .failed, message: String(describing: e)) }
        switch e {
        case .notRecording: return IPCError(code: .notRecording, message: "録音中ではありません")
        case .alreadyRecording: return IPCError(code: .alreadyRecording, message: "すでに録音中です")
        case .notFound(let m): return IPCError(code: .notFound, message: m)
        case .invalid(let m): return IPCError(code: .invalidArgs, message: m)
        case .failed(let m): return IPCError(code: .failed, message: m)
        }
    }

    private func run(_ request: IPCRequest) async throws -> IPCResult {
        let args = request.args
        switch request.cmd {
        case .status:
            return IPCResult(status: await status())
        case .start:
            try await ports.recorder.start(language: args.lang)
            return IPCResult()
        case .stop:
            try await ports.recorder.stop()
            return IPCResult()
        case .pause:
            try await ports.recorder.pause()
            return IPCResult()
        case .resume:
            try await ports.recorder.resume()
            return IPCResult()
        case .bookmark:
            return IPCResult(bookmark: try await ports.recorder.bookmark(note: args.note))
        case .list:
            var rows = try await ports.meetings.rows()
            if let since = args.since { rows = try MeetingListBuilder.filter(rows, since: since, calendar: calendar) }
            return IPCResult(meetings: rows)
        case .latest:
            guard let file = try await ports.meetings.latestMinutesFile() else { throw AppCommandError.notFound("議事録がまだありません") }
            if args.open == true { await ports.opener.open(file) }
            return IPCResult(path: file.path)
        case .import:
            guard let path = args.file else { throw AppCommandError.invalid("ファイルを指定してください") }
            let url = URL(filePath: path)
            guard path.hasPrefix("/") else { throw AppCommandError.invalid("ファイルは絶対パスで渡してください") }
            guard FileManager.default.fileExists(atPath: url.path) else { throw AppCommandError.notFound("ファイルがありません: \(path)") }
            return IPCResult(meetingID: try await ports.meetings.importAudio(url, startedAt: nil).rawValue)
        case .regenerate:
            guard let id = args.meetingID else { throw AppCommandError.invalid("会議 ID が要ります") }
            try await ports.queue.regenerate(MeetingID(rawValue: id))
            return IPCResult()
        case .automationsList:
            return IPCResult(automations: await ports.automations.summaries().0)
        case .automationsRun:
            guard let name = args.name, let id = args.meetingID else { throw AppCommandError.invalid("Automation の名前と会議 ID が要ります") }
            return IPCResult(run: try await ports.automations.run(name: name, meetingID: MeetingID(rawValue: id)))
        }
    }

    private func status() async -> StatusResult {
        let snap = await ports.recorder.current()
        var recorder = RecorderStatusDTO(state: snap.state.rawValue, meetingID: snap.meetingID?.rawValue, device: snap.deviceName,
                                         language: snap.language)
        let current = now()
        switch snap.state {
        case .idle:
            break
        case .countdown:
            recorder.secondsRemaining = remaining(snap.deadline, from: current)
        case .grace:
            recorder.secondsRemaining = remaining(snap.deadline, from: current)
            recorder.elapsedSeconds = await elapsed(snap, from: current)
        case .recording, .paused:
            recorder.elapsedSeconds = await elapsed(snap, from: current)
        }
        // Finished jobs stay in the queue only for failure notices (X15); the CLI does not list them.
        let items = await ports.queue.status().items.filter { $0.state != "done" }.map { item -> QueueItemDTO in
            var item = item
            if item.label.isEmpty { item.label = StageLabel.text(stage: item.stage, progress: item.progress) }
            return item
        }
        return StatusResult(recorder: recorder, queue: items, outputFolderAvailable: await ports.outputFolder.isAvailable())
    }

    private func remaining(_ deadline: Date?, from current: Date) -> Int? {
        deadline.map { max(0, Int($0.timeIntervalSince(current).rounded(.up))) }
    }

    private func elapsed(_ snap: RecorderSnapshot, from current: Date) async -> Int? {
        guard snap.meetingID != nil else { return nil }
        if let t = await ports.recorder.elapsed() { return max(0, Int(t.seconds)) }
        return snap.startedAt.map { max(0, Int(current.timeIntervalSince($0))) }
    }
}
