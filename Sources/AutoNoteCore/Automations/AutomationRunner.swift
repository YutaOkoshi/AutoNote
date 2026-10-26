import Darwin
import Foundation

/// Runs an automation under `shell + [command]` in its own process group. Runs are not globally serialized
/// (the actor is re-entrant across `await`); the dedupe key is recorded before the first `await`.
/// On timeout the group gets SIGTERM, then SIGKILL after `killGrace`. Each run gets a log folder
/// `logsDirectory/<yyyyMMdd-HHmmss>-<meeting-id>-<name>/` with `stdout.txt`, `stderr.txt`, `result.json`;
/// only the newest `maxLogRuns` folders are kept. A non-nil `dedupeKey` is recorded in `ledgerFile` before the
/// command starts, so a key never runs twice, even across app restarts or a crash mid-run.
public actor AutomationRunner {
    public static let defaultShell: [String] = ["/bin/zsh", "-lc"]
    static let alreadyRan = "already_ran"
    static let spawnFailed = "spawn_failed"

    private let logsDirectory: URL
    private let ledgerFile: URL
    private let shell: [String]
    private let killGrace: Duration
    private let maxLogRuns: Int
    private var subscribers: [UUID: AsyncStream<AutomationRunRecord>.Continuation] = [:]

    public init(logsDirectory: URL, ledgerFile: URL, shell: [String] = defaultShell, killGrace: Duration = .seconds(5),
                maxLogRuns: Int = 200) {
        self.logsDirectory = logsDirectory
        self.ledgerFile = ledgerFile
        self.shell = shell
        self.killGrace = killGrace
        self.maxLogRuns = maxLogRuns
    }

    public func run(_ def: AutomationDefinition, context: AutomationContext, dedupeKey: String?) async -> AutomationRunRecord {
        let startedAt = Date()
        if let key = dedupeKey {
            var ledger = readLedger()
            if ledger.contains(key) {
                return AutomationRunRecord(name: def.name, event: context.event, meetingID: context.meetingID.rawValue,
                                           startedAt: startedAt, durationSeconds: 0, exitCode: nil, timedOut: false,
                                           skippedReason: Self.alreadyRan, logDirectory: "")
            }
            ledger.append(key)
            writeLedger(ledger)   // before any await, so a re-entrant run with the same key sees it
        }

        let folder = makeLogFolder(startedAt: startedAt, meetingID: context.meetingID.rawValue, name: def.name)
        let stdoutFile = folder.appending(path: "stdout.txt")
        let stderrFile = folder.appending(path: "stderr.txt")
        var env = ProcessInfo.processInfo.environment
        env.merge(context.environment()) { _, new in new }

        var exitCode: Int32?
        var timedOut = false
        var skippedReason: String?
        do {
            let pid = try ProcessGroupSpawner.spawn(arguments: shell + [def.command], environment: env,
                                                    stdin: try context.stdinJSON(), stdoutFile: stdoutFile,
                                                    stderrFile: stderrFile)
            (exitCode, timedOut) = await wait(pid: pid, timeout: .seconds(max(def.timeoutSec, 0)))
        } catch {
            skippedReason = Self.spawnFailed
            try? Data("\(error)\n".utf8).write(to: stderrFile)
        }

        let draft = AutomationRunRecord(name: def.name, event: context.event, meetingID: context.meetingID.rawValue,
                                        startedAt: startedAt, durationSeconds: Date().timeIntervalSince(startedAt),
                                        exitCode: exitCode, timedOut: timedOut, skippedReason: skippedReason,
                                        logDirectory: folder.path)
        let record = writeResult(draft, in: folder)
        pruneLogs()
        for sub in subscribers.values { sub.yield(record) }
        return record
    }

    /// Newest first, read from the log folders' `result.json`.
    public func recentRuns(limit: Int) async -> [AutomationRunRecord] {
        let decoder = AutoNoteJSON.decoder()
        var out: [AutomationRunRecord] = []
        for folder in sortedLogFolders().reversed() where out.count < limit {
            guard let data = try? Data(contentsOf: folder.appending(path: "result.json")),
                  let rec = try? decoder.decode(AutomationRunRecord.self, from: data) else { continue }
            out.append(rec)
        }
        return out
    }

    /// Yields every completed run (not `already_ran` skips) from now on.
    public func records() -> AsyncStream<AutomationRunRecord> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AutomationRunRecord>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    // MARK: Waiting and killing

    private func wait(pid: pid_t, timeout: Duration) async -> (exitCode: Int32?, timedOut: Bool) {
        let watch = ChildWatch()
        let grace = killGrace
        let timer = Task.detached {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, watch.markTimedOutIfRunning() else { return }
            kill(-pid, SIGTERM)
            let deadline = ContinuousClock.now + grace
            while ContinuousClock.now < deadline {
                if watch.exited && kill(-pid, 0) == -1 { return }   // shell and the rest of its group are gone
                try? await Task.sleep(for: .milliseconds(50))
            }
            kill(-pid, SIGKILL)
        }
        let status = await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            Thread.detachNewThread { cont.resume(returning: ProcessGroupSpawner.waitBlocking(pid)) }
        }
        let timedOut = watch.markExited()
        if timedOut { await timer.value } else { timer.cancel() }
        // Normal exit: low 7 bits are 0 and the code is in bits 8-15. Anything else is a signal (or a wait error).
        let exitCode: Int32? = status != -1 && (status & 0x7F) == 0 ? (status >> 8) & 0xFF : nil
        return (exitCode, timedOut)
    }

    // MARK: Ledger

    private func readLedger() -> [String] {
        guard let data = try? Data(contentsOf: ledgerFile) else { return [] }
        return (try? AutoNoteJSON.decoder().decode([String].self, from: data)) ?? []
    }

    private func writeLedger(_ keys: [String]) {
        try? FileManager.default.createDirectory(at: ledgerFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? AutoNoteJSON.encoder().encode(keys) else { return }
        try? data.write(to: ledgerFile, options: .atomic)
    }

    // MARK: Logs

    private func makeLogFolder(startedAt: Date, meetingID: String, name: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(formatter.string(from: startedAt))-\(Self.sanitize(meetingID))-\(Self.sanitize(name))"
        var folder = logsDirectory.appending(path: base)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = logsDirectory.appending(path: "\(base)-\(n)")
            n += 1
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Keeps `[A-Za-z0-9-]`, turns every other run of characters into one `-`, trims `-` at the ends.
    static func sanitize(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            let ok = ch.isASCII && (CharacterSet.alphanumerics.contains(ch) || ch == "-")
            if ok { out.unicodeScalars.append(ch) } else if !out.hasSuffix("-") { out.append("-") }
        }
        while out.hasSuffix("-") { out.removeLast() }
        while out.hasPrefix("-") { out.removeFirst() }
        return out.isEmpty ? "automation" : out
    }

    /// Writes `result.json` and returns the record as decoded from it, so the returned value and the file agree
    /// exactly (dates are stored with millisecond precision).
    private func writeResult(_ record: AutomationRunRecord, in folder: URL) -> AutomationRunRecord {
        guard let data = try? AutoNoteJSON.encoder().encode(record) else { return record }
        try? data.write(to: folder.appending(path: "result.json"), options: .atomic)
        return (try? AutoNoteJSON.decoder().decode(AutomationRunRecord.self, from: data)) ?? record
    }

    /// Oldest first. Folder names start with a second-resolution timestamp; ties break on creation time.
    private func sortedLogFolders() -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: keys)
        else { return [] }
        let folders = items.compactMap { url -> (URL, String, Date)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isDirectory == true else { return nil }
            return (url, String(url.lastPathComponent.prefix(15)), v.creationDate ?? .distantPast)
        }
        return folders.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.2 != b.2 { return a.2 < b.2 }
            return a.0.lastPathComponent < b.0.lastPathComponent
        }.map(\.0)
    }

    private func pruneLogs() {
        let folders = sortedLogFolders()
        guard folders.count > maxLogRuns else { return }
        for folder in folders.prefix(folders.count - max(maxLogRuns, 0)) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

/// Lock-protected flags shared by the waiter and the timeout task.
private final class ChildWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var _exited = false
    private var _timedOut = false

    var exited: Bool { lock.withLock { _exited } }

    /// Returns true when the timeout wins (the child had not exited yet).
    func markTimedOutIfRunning() -> Bool {
        lock.withLock {
            if _exited { return false }
            _timedOut = true
            return true
        }
    }

    /// Records the exit and returns whether the timeout path fired.
    func markExited() -> Bool {
        lock.withLock {
            _exited = true
            return _timedOut
        }
    }
}
