import Foundation

/// Everything the install helper needs; it runs after the app has quit.
public struct UpdateInstallPlan: Equatable, Sendable {
    /// The app process to wait for.
    public var pid: Int32
    /// The running `.app` (replaced in place, so its path, login item and permissions stay).
    public var target: URL
    /// The checked, unpacked new `.app`.
    public var staged: URL
    /// Where the old app waits during the swap: next to `target`, so the moves stay on one volume.
    public var backup: URL
    public var requirement: String
    public var resultFile: URL
    public var logFile: URL
    public var fromVersion: String
    public var toVersion: String
    /// `AUTONOTE_*` variables handed to the relaunched app (`open --env`), so a development run keeps its data
    /// directory and feed. Empty for a normal launch.
    public var environment: [String: String]
    /// How long the helper waits for the app to quit, and how long after `open` it checks that the new one runs.
    public var quitTimeoutSeconds: Int = 60
    public var launchCheckSeconds: Int = 5

    public init(pid: Int32, target: URL, staged: URL, requirement: String, resultFile: URL, logFile: URL,
                fromVersion: String, toVersion: String, environment: [String: String]) {
        self.pid = pid
        self.target = target
        self.staged = staged
        self.backup = target.deletingLastPathComponent()
            .appending(path: ".\(target.deletingPathExtension().lastPathComponent)-update-backup.app", directoryHint: .isDirectory)
        self.requirement = requirement
        self.resultFile = resultFile
        self.logFile = logFile
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.environment = environment
    }

    /// The `AUTONOTE_*` entries of `environment` (the only ones a relaunch carries over).
    public static func relaunchEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { $0.key.hasPrefix("AUTONOTE_") }
    }

    /// The helper's argument vector after the script path.
    public var arguments: [String] {
        [String(pid), target.path, staged.path, backup.path, requirement, resultFile.path, logFile.path,
         fromVersion, toVersion, String(quitTimeoutSeconds), String(launchCheckSeconds)]
            + environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }
}

/// Writes the helper script and starts it detached; the app then quits and the helper does the swap.
public enum UpdateInstaller {
    /// Steps: wait for the app to quit → move the old app aside → move the new one in → check its signature against
    /// the old app's requirement → `open -n` it → check it runs. Any failure after the old app moved puts it back and
    /// starts it. The result goes to `last-install.json` for the next launch to read.
    public static let script = #"""
    #!/bin/bash
    # AutoNote の入れ替えの補助。アプリが終了したあとに動く（UpdateInstaller が書いて起動する）。
    set -u
    PID="$1"; TARGET="$2"; STAGED="$3"; BACKUP="$4"; REQ="$5"; RESULT="$6"; LOG="$7"
    FROM="$8"; TO="$9"; shift 9
    QUIT_TIMEOUT="$1"; LAUNCH_CHECK="$2"; shift 2
    OPEN_ARGS=(-n)
    for kv in "$@"; do OPEN_ARGS+=(--env "$kv"); done
    exec >>"$LOG" 2>&1
    log() { echo "$(/bin/date '+%Y-%m-%dT%H:%M:%S') $*"; }
    result() {
        printf '{"from":"%s","to":"%s","result":"%s","reason":"%s"}\n' "$FROM" "$TO" "$1" "$2" >"$RESULT.tmp" \
            && /bin/mv -f "$RESULT.tmp" "$RESULT"
    }
    running() { /bin/ps -axo command= | /usr/bin/grep -F -- "$TARGET/Contents/MacOS/" | /usr/bin/grep -v -F -- "$0" >/dev/null; }
    launch() { /usr/bin/open "${OPEN_ARGS[@]}" "$TARGET"; }
    restore() {
        log "失敗（$1）: 元の版に戻す"
        /bin/rm -rf "$TARGET"
        if /bin/mv "$BACKUP" "$TARGET"; then log "元の版を戻した"; else log "元の版を戻せない: $BACKUP"; fi
        result restored "$1"
        launch || log "元の版を起動できない"
        exit 1
    }

    log "開始: $FROM → $TO（pid $PID の終了を待つ）"
    waited=0
    while /bin/kill -0 "$PID" 2>/dev/null; do
        if [ "$waited" -ge $((QUIT_TIMEOUT * 5)) ]; then
            log "アプリが ${QUIT_TIMEOUT} 秒で終了しない。何もしない"
            result skipped timeout
            exit 1
        fi
        /bin/sleep 0.2; waited=$((waited + 1))
    done

    [ -e "$BACKUP" ] && /bin/rm -rf "$BACKUP"
    if ! /bin/mv "$TARGET" "$BACKUP"; then
        log "今のアプリを退避できない"
        result restored move-aside
        launch
        exit 1
    fi
    /bin/mv "$STAGED" "$TARGET" || restore move-new
    /usr/bin/codesign --verify --strict "-R=$REQ" "$TARGET" || restore verify
    launch || restore launch
    /bin/sleep "$LAUNCH_CHECK"
    running || restore launch
    /bin/rm -rf "$BACKUP"
    result installed ""
    log "完了: $TO を起動した"
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
}
