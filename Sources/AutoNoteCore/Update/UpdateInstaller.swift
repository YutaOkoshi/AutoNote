import Foundation

/// Everything the install helper needs; it runs after the app has quit.
public struct UpdateInstallPlan: Equatable, Sendable {
    /// The app process to wait for.
    public var pid: Int32
    /// The running `.app` (replaced in place, so its path, login item and permissions stay).
    public var target: URL
    /// The checked, unpacked new `.app`.
    public var staged: URL
    /// Next to `target`: the new app is moved here first (same volume), then swapped with `target` in one
    /// `renamex_np(RENAME_SWAP)`, so `target` always holds a whole app (review L3). After the swap it holds the old
    /// app until the new one is seen running.
    public var swapPath: URL
    public var requirement: String
    public var resultFile: URL
    public var logFile: URL
    /// The new app writes its pid here as it starts (`AUTONOTE_UPDATE_LAUNCH_MARKER`); the helper waits for it.
    public var launchMarker: URL
    /// Held (a folder with the helper's pid) while a helper runs: a second helper, or the app's leftover sweep, keeps
    /// out of the way.
    public var lockDirectory: URL
    public var fromVersion: String
    public var toVersion: String
    /// `AUTONOTE_*` variables handed to the relaunched app (`open --env`), so a development run keeps its data
    /// directory and feed. Empty for a normal launch.
    public var environment: [String: String]
    /// How long the helper waits for the app to quit, and for the new app's launch marker.
    public var quitTimeoutSeconds: Int = 60
    public var launchCheckSeconds: Int = 20

    public static let launchMarkerKey = "AUTONOTE_UPDATE_LAUNCH_MARKER"

    public init(pid: Int32, target: URL, staged: URL, requirement: String, directory: URL,
                fromVersion: String, toVersion: String, environment: [String: String]) {
        self.pid = pid
        self.target = target
        self.staged = staged
        self.swapPath = Self.swapPath(for: target)
        self.requirement = requirement
        self.resultFile = directory.appending(path: "last-install.json")
        self.logFile = directory.appending(path: "install.log")
        self.launchMarker = directory.appending(path: "launched.pid")
        self.lockDirectory = directory.appending(path: "install.lock", directoryHint: .isDirectory)
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.environment = environment
    }

    /// `.<name>-update.app` beside `target`.
    public static func swapPath(for target: URL) -> URL {
        target.deletingLastPathComponent()
            .appending(path: ".\(target.deletingPathExtension().lastPathComponent)-update.app", directoryHint: .isDirectory)
    }

    /// What an earlier helper version left beside `target` (`.<name>-update-backup.app`).
    public static func legacyBackupPath(for target: URL) -> URL {
        target.deletingLastPathComponent()
            .appending(path: ".\(target.deletingPathExtension().lastPathComponent)-update-backup.app", directoryHint: .isDirectory)
    }

    /// The `AUTONOTE_*` entries of `environment` (the only ones a relaunch carries over), without a launch marker of
    /// an earlier swap.
    public static func relaunchEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { $0.key.hasPrefix("AUTONOTE_") && $0.key != launchMarkerKey }
    }

    /// The helper's argument vector after the script path.
    public var arguments: [String] {
        [String(pid), target.path, staged.path, swapPath.path, requirement, resultFile.path, logFile.path,
         launchMarker.path, lockDirectory.path, fromVersion, toVersion, String(quitTimeoutSeconds),
         String(launchCheckSeconds)]
            + environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }
}

public enum UpdateSwapError: Error, Equatable, Sendable {
    case failed(Int32)
}

/// Writes the helper script and starts it detached; the app then quits and the helper does the swap.
public enum UpdateInstaller {
    /// Swaps two paths on one volume in a single step (`renamex_np(RENAME_SWAP)`): neither is ever missing.
    /// The helper calls it through `autonote dev update --swap` (a shell has no such call).
    public static func swap(_ a: URL, _ b: URL) throws(UpdateSwapError) {
        guard renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 else { throw .failed(errno) }
    }

    /// Steps: take the lock → wait for the app to quit → sweep what an interrupted helper left → the staged app is a
    /// real folder → move it beside the app → check it (`--deep --strict` against the old app's requirement) → swap it
    /// with the app in one step → `open -n` it → wait for its launch marker and check that pid runs → remove the old
    /// app. A failure after the swap stops the new app's processes, swaps back and starts the old app. The result goes
    /// to `last-install.json` (`installed` just before the new app starts, `restored` when that then fails).
    public static let script = #"""
    #!/bin/bash
    # AutoNote の入れ替えの補助。アプリが終了したあとに動く（UpdateInstaller が書いて起動する）。
    set -u
    PID="$1"; TARGET="$2"; STAGED="$3"; SWAP="$4"; REQ="$5"; RESULT="$6"; LOG="$7"; MARKER="$8"; LOCK="$9"; shift 9
    FROM="$1"; TO="$2"; QUIT_TIMEOUT="$3"; LAUNCH_CHECK="$4"; shift 4
    OPEN_ARGS=(-n --env "AUTONOTE_UPDATE_LAUNCH_MARKER=${MARKER}")
    for kv in "$@"; do OPEN_ARGS+=(--env "$kv"); done
    LEGACY="$(/usr/bin/dirname "${TARGET}")/.$(/usr/bin/basename "${TARGET}" .app)-update-backup.app"
    exec >>"${LOG}" 2>&1
    log() { echo "$(/bin/date '+%Y-%m-%dT%H:%M:%S') $*"; }
    result() {
        printf '{"from":"%s","to":"%s","result":"%s","reason":"%s"}\n' "${FROM}" "${TO}" "$1" "$2" >"${RESULT}.tmp" \
            && /bin/mv -f "${RESULT}.tmp" "${RESULT}"
    }
    launch() { /bin/rm -f "${MARKER}"; /usr/bin/open "${OPEN_ARGS[@]}" "${TARGET}"; }
    # 入れ替えは autonote の CLI（renamex_np の RENAME_SWAP）で 1 回で行う。どちらのパスも消える瞬間が無い
    swap() { "$1/Contents/MacOS/autonote" dev update --swap "${TARGET}" "${SWAP}"; }
    is_dir() { [ -d "$1" ] && [ ! -L "$1" ]; }
    # TARGET の中の実行ファイルから動いているプロセスの pid（パスを書き換えた表記も拾う）
    target_pids() {
        local real
        local -a pat
        pat=(-e "${TARGET}/Contents/MacOS/")
        real="$(cd "${TARGET}" 2>/dev/null && /bin/pwd -P)"
        [ -n "${real}" ] && pat+=(-e "${real}/Contents/MacOS/")
        /bin/ps -axo pid=,command= | /usr/bin/grep -F "${pat[@]}" | /usr/bin/grep -v -F -e "$0" \
            | /usr/bin/awk '$2 !~ /grep$/ {print $1}'
    }
    stop_new() {
        local pids i
        pids="$(target_pids)"
        [ -n "${pids}" ] || return 0
        log "新しい版のプロセスを止める: $(echo ${pids})"
        /bin/kill ${pids} 2>/dev/null
        for i in $(/usr/bin/jot 50); do [ -n "$(target_pids)" ] || return 0; /bin/sleep 0.1; done
        /bin/kill -9 $(target_pids) 2>/dev/null
    }
    fail_before_swap() {
        log "失敗（$1）: 何も入れ替えずに元の版を起動する"
        is_dir "${SWAP}" && /bin/rm -rf "${SWAP}"
        result restored "$1"
        launch || log "元の版を起動できない"
        exit 1
    }
    fail_after_swap() {
        log "失敗（$1）: 元の版に戻す"
        stop_new
        if swap "${SWAP}"; then log "元の版を戻した"; /bin/rm -rf "${SWAP}"; else log "元の版を戻せない: ${SWAP}"; fi
        result restored "$1"
        launch || log "元の版を起動できない"
        exit 1
    }

    # 補助は 1 つだけ: ロックが生きている補助のものなら何もしない
    if ! /bin/mkdir "${LOCK}" 2>/dev/null; then
        other="$(/bin/cat "${LOCK}/pid" 2>/dev/null)"
        if [ -n "${other}" ] && /bin/kill -0 "${other}" 2>/dev/null; then log "別の補助（pid ${other}）が動いている。何もしない"; exit 1; fi
        /bin/rm -rf "${LOCK}"
        /bin/mkdir "${LOCK}" || { log "ロックを取れない"; exit 1; }
    fi
    echo $$ >"${LOCK}/pid"
    trap '/bin/rm -rf "${LOCK}"' EXIT

    log "開始: ${FROM} → ${TO}（pid ${PID} の終了を待つ）"
    waited=0
    while /bin/kill -0 "${PID}" 2>/dev/null; do
        if [ "$waited" -ge $((QUIT_TIMEOUT * 5)) ]; then
            log "アプリが ${QUIT_TIMEOUT} 秒で終了しない。何もしない"
            result skipped timeout
            exit 1
        fi
        /bin/sleep 0.2; waited=$((waited + 1))
    done

    # 途中で止まった前回の入れ替えの後始末: アプリが無ければ退避から戻し、残った退避は消す
    if [ ! -e "${TARGET}" ]; then
        for left in "${SWAP}" "${LEGACY}"; do
            if is_dir "${left}"; then log "アプリが無い。${left} から戻す"; /bin/mv "${left}" "${TARGET}" && break; fi
        done
    fi
    is_dir "${TARGET}" || { log "アプリが無い: ${TARGET}"; result restored move-aside; exit 1; }
    [ -e "${SWAP}" ] || [ -L "${SWAP}" ] && /bin/rm -rf "${SWAP}"
    [ -e "${LEGACY}" ] || [ -L "${LEGACY}" ] && /bin/rm -rf "${LEGACY}"

    is_dir "${STAGED}" && is_dir "$(/usr/bin/dirname "${STAGED}")" || fail_before_swap staged
    /bin/mv "${STAGED}" "${SWAP}" || fail_before_swap move-new
    is_dir "${SWAP}" || fail_before_swap staged
    /usr/bin/codesign --verify --deep --strict "-R=${REQ}" "${SWAP}" || fail_before_swap verify
    swap "${TARGET}" || fail_before_swap swap
    # ここから TARGET が新しい版、SWAP が元の版
    # Written before the launch: the new app reads (and removes) it as it starts. A failed check below overwrites it
    # with `restored`, which the restarted old app reads.
    result installed ""
    launch || fail_after_swap launch
    started=""
    for i in $(/usr/bin/jot $((LAUNCH_CHECK * 5))); do
        started="$(/bin/cat "${MARKER}" 2>/dev/null)"
        [ -n "${started}" ] && break
        /bin/sleep 0.2
    done
    [ -n "${started}" ] || fail_after_swap launch
    /bin/sleep 2
    /bin/kill -0 "${started}" 2>/dev/null || fail_after_swap launch
    /bin/rm -rf "${SWAP}" "${MARKER}"
    log "完了: ${TO} を起動した（pid ${started}）"
    """#

    /// Writes `install.sh` into `directory` and starts it. The helper outlives the app (it is reparented when the
    /// app exits) and does nothing until the app's process is gone.
    public static func launch(_ plan: UpdateInstallPlan, directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appending(path: "install.sh")
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [scriptURL.path] + plan.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // A clean environment: nothing of the app's (DYLD_*, tokens) reaches the helper; what the relaunch needs
        // travels as arguments.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        try process.run()
    }

    /// Whether a helper holds `lockDirectory` (its pid is alive).
    public static func helperIsRunning(lockDirectory: URL) -> Bool {
        guard let text = try? String(contentsOf: lockDirectory.appending(path: "pid"), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0
    }

    /// At launch, with no helper running: removes what an interrupted swap left beside `target` (the swap slot and an
    /// earlier version's backup). `target` itself is whole at all times, so nothing needs restoring from here.
    public static func sweepLeftovers(target: URL, lockDirectory: URL) -> [URL] {
        guard !helperIsRunning(lockDirectory: lockDirectory) else { return [] }
        var removed: [URL] = []
        for left in [UpdateInstallPlan.swapPath(for: target), UpdateInstallPlan.legacyBackupPath(for: target)] {
            var st = stat()
            guard lstat(left.path, &st) == 0 else { continue }
            if (try? FileManager.default.removeItem(at: left)) != nil { removed.append(left) }
        }
        return removed
    }

    /// The new app, started by the helper with `AUTONOTE_UPDATE_LAUNCH_MARKER`, writes its pid there — only when
    /// the path is the marker in this app's own updates folder.
    public static func writeLaunchMarker(environment: [String: String], directory: URL,
                                         pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        guard let raw = environment[UpdateInstallPlan.launchMarkerKey] else { return }
        let expected = directory.appending(path: "launched.pid").standardizedFileURL.path
        guard URL(filePath: raw).standardizedFileURL.path == expected else { return }
        try? Data("\(pid)\n".utf8).write(to: URL(filePath: expected), options: .atomic)
    }
}
