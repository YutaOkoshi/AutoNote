import Foundation

/// Writes a fake `claude` shell script into a temporary folder for tests. The real `claude` is never run.
///
/// `claude auth …` prints `auth` and exits 0. Any other call n (counted in `dir/count`) saves its arguments
/// NUL-separated to `dir/args-<n>`, stdin to `dir/stdin-<n>`, `pwd -P` to `dir/cwd-<n>` and the
/// working directory listing (`ls -A`) to `dir/ls-<n>`, optionally sleeps,
/// prints `responses[n-1]` (the last one once they run out) and exits with `exitCode`.
enum FakeClaude {
    static func make(in dir: URL, auth: String = #"{"loggedIn":true}"#, responses: [String],
                     exitCode: Int32 = 0, sleepSeconds: Int = 0) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(auth.utf8).write(to: dir.appending(path: "auth-response"))
        for (i, r) in responses.enumerated() {
            try Data(r.utf8).write(to: dir.appending(path: "response-\(i + 1)"))
        }
        let quotedDir = "'" + dir.path(percentEncoded: false).replacing("'", with: #"'\''"#) + "'"
        let script = """
        #!/bin/sh
        D=\(quotedDir)
        if [ "$1" = "auth" ]; then cat "$D/auth-response"; exit 0; fi
        n=$(( $(cat "$D/count" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$D/count"
        for a in "$@"; do printf '%s\\0' "$a"; done > "$D/args-$n"
        cat > "$D/stdin-$n"
        pwd -P > "$D/cwd-$n"
        ls -A > "$D/ls-$n"
        if [ \(sleepSeconds) -gt 0 ]; then sleep \(sleepSeconds); fi
        k=$n
        if [ "$k" -gt \(responses.count) ]; then k=\(responses.count); fi
        cat "$D/response-$k"
        exit \(exitCode)

        """
        let url = dir.appending(path: "claude")
        try Data(script.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }

    static func count(in dir: URL) -> Int {
        guard let s = try? String(contentsOf: dir.appending(path: "count"), encoding: .utf8) else { return 0 }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    static func arguments(in dir: URL, call n: Int) throws -> [String] {
        let data = try Data(contentsOf: dir.appending(path: "args-\(n)"))
        var parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    static func stdin(in dir: URL, call n: Int) throws -> String {
        try String(contentsOf: dir.appending(path: "stdin-\(n)"), encoding: .utf8)
    }

    static func listing(in dir: URL, call n: Int) throws -> [String] {
        try String(contentsOf: dir.appending(path: "ls-\(n)"), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    static func cwd(in dir: URL, call n: Int) throws -> String {
        try String(contentsOf: dir.appending(path: "cwd-\(n)"), encoding: .utf8).trimmingCharacters(in: .newlines)
    }
}
