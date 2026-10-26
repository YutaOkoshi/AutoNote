import Foundation

public struct CLIOutput: Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum CLIRenderer {
    public static let usage = """
    usage: autonote start [--lang auto|ja|en]
           autonote stop | pause | resume
           autonote bookmark [メモ]
           autonote status [--json]
           autonote list [--since YYYY-MM-DD] [--json]
           autonote latest [--open] [--json]
           autonote import <file>
           autonote regenerate <id>
           autonote automations list [--json]
           autonote automations run <名前> <id>
           autonote --version
    """ + "\n"

    public static func render(_ r: IPCResponse, for inv: CLIInvocation, timeZone: TimeZone = .current) -> CLIOutput {
        guard r.ok else {
            return failure(r.error ?? IPCError(code: .failed, message: "不明なエラー"), json: inv.json)
        }
        let result = r.result ?? IPCResult()
        if inv.json { return CLIOutput(stdout: jsonLine(result)) }

        switch inv.command {
        case .start: return CLIOutput(stdout: "録音を開始しました\n")
        case .stop: return CLIOutput(stdout: "録音を停止しました\n")
        case .pause: return CLIOutput(stdout: "録音を一時停止しました\n")
        case .resume: return CLIOutput(stdout: "録音を再開しました\n")
        case .bookmark: return CLIOutput(stdout: "ブックマークを追加しました\n")
        case .status: return CLIOutput(stdout: statusText(result.status ?? StatusResult()))
        case .list: return CLIOutput(stdout: listText(result.meetings ?? [], timeZone: timeZone))
        case .latest: return CLIOutput(stdout: (result.path ?? "") + "\n")
        case .import, .regenerate: return CLIOutput(stdout: "受け付けました: \(result.meetingID ?? inv.args.meetingID ?? "")\n")
        case .automationsList: return CLIOutput(stdout: automationsText(result.automations ?? []))
        case .automationsRun: return runOutput(result.run)
        }
    }

    public static func render(_ e: SocketClientError, json: Bool, timeoutSeconds: Int = 10) -> CLIOutput {
        let message: String
        switch e {
        case .timedOut: message = "AutoNote が \(timeoutSeconds) 秒以内に応答しませんでした"
        case .appNotRunning: message = "AutoNote が起動していません"
        case .launchFailed(let m): message = "AutoNote を起動できませんでした: \(m)"
        case .protocolError(let m): message = "AutoNote との通信に失敗しました: \(m)"
        }
        return failure(IPCError(code: .failed, message: message), json: json)
    }

    public static func render(_ e: CLIUsageError) -> CLIOutput {
        CLIOutput(stderr: "エラー: \(e.message)\n" + usage, exitCode: 1)
    }

    // MARK: - Pieces

    private static func failure(_ error: IPCError, json: Bool) -> CLIOutput {
        if json {
            struct Envelope: Encodable { var error: IPCError }
            return CLIOutput(stdout: jsonLine(Envelope(error: error)), exitCode: 1)
        }
        return CLIOutput(stderr: "エラー: \(error.message)\n", exitCode: 1)
    }

    private static func jsonLine(_ value: some Encodable) -> String {
        let data = (try? AutoNoteJSON.compactEncoder().encode(value)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func statusText(_ s: StatusResult) -> String {
        var out = "録音器: " + recorderText(s.recorder) + "\n"
        if s.queue.isEmpty {
            out += "待ち行列: なし\n"
        } else {
            out += "待ち行列:\n"
            for item in s.queue { out += "  \(item.meetingID)  \(queueLabel(item))\n" }
        }
        if !s.outputFolderAvailable { out += "出力フォルダが見つかりません\n" }
        return out
    }

    private static func recorderText(_ r: RecorderStatusDTO) -> String {
        let clock = clockText(r.elapsedSeconds ?? 0)
        let device = r.device.map { "（\($0)）" } ?? ""
        switch r.state {
        case "recording": return "録音中 \(clock)\(device)"
        case "paused": return "一時停止中 \(clock)\(device)"
        case "countdown": return "開始待ち" + (r.secondsRemaining.map { "（あと \($0) 秒）" } ?? "")
        case "grace": return "終了待ち" + (r.secondsRemaining.map { "（あと \($0) 秒）" } ?? "")
        case "idle": return "待機"
        default: return r.state
        }
    }

    private static func clockText(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private static func queueLabel(_ q: QueueItemDTO) -> String {
        if q.notBefore != nil { return "再試行待ち" }
        if q.awaitingConfirmation { return "上書きの確認待ち" }
        if q.state == "failed" { return "失敗: \(q.message ?? q.label)" }
        return q.label
    }

    private static func listText(_ rows: [MeetingRow], timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return rows.map { row in
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: row.startedAt)
            let when = String(format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
            let minutes = row.durationMinutes.map { "\($0) 分" } ?? "-"
            return "\(when)  \(minutes)  \(row.title)  \(row.state.displayText(progressLabel: row.progressLabel))  \(row.id)\n"
        }.joined()
    }

    private static func automationsText(_ list: [AutomationSummary]) -> String {
        list.map { a in
            let state = a.enabled ? "有効" : "無効" + (a.problem.map { "（\($0)）" } ?? "")
            return "\(a.name)  \(a.on.rawValue)  \(state)\n"
        }.joined()
    }

    private static func runOutput(_ run: AutomationRunRecord?) -> CLIOutput {
        guard let run else { return CLIOutput(stderr: "エラー: 実行結果がありません\n", exitCode: 1) }
        if let reason = run.skippedReason {
            return CLIOutput(stdout: reason == "already_ran" ? "実行済みのためスキップしました\n" : "スキップしました: \(reason)\n")
        }
        if let m = run.failureMessage { return CLIOutput(stderr: "エラー: \(m)\n", exitCode: 1) }
        let seconds = String(format: "%.1f", run.durationSeconds)
        if run.timedOut { return CLIOutput(stdout: "タイムアウトしました（\(seconds) 秒）ログ: \(run.logDirectory)\n", exitCode: 1) }
        let code = run.exitCode ?? 1
        return CLIOutput(stdout: "終了コード \(code)（\(seconds) 秒）ログ: \(run.logDirectory)\n", exitCode: code)
    }
}
