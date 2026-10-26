import Foundation
import Synchronization
import whisper

/// whisper.cpp（XCFramework）への最小限の窓口。`import whisper` は AutoNoteCore の中だけで行う。
enum WhisperRuntime {
    /// whisper.cpp が報告する CPU/GPU 機能の一覧（例: `AVX = 1 | ...`）。
    /// `whisper_print_system_info` は関数内の static な std::string を書き換えて返すので、同時に呼ぶと壊れる（並列テストで abort した）。
    /// 呼び出しと複製を `systemInfoLock` で直列にする。
    static func systemInfo() -> String {
        installQuietLogging()
        return systemInfoLock.withLock { _ in String(cString: whisper_print_system_info()) }
    }

    private static let systemInfoLock = Mutex<Void>(())

    /// 言語コード（`ja`・`en` など）の whisper 内部 ID。未知のコードは -1。
    static func languageID(_ code: String) -> Int32 {
        whisper_lang_id(code)
    }

    /// whisper / ggml のログを ERROR 以上だけ stderr に出すようにする（初回だけ効く）。
    /// 既定では `ggml_metal_*` などの情報ログがテスト出力やコンソールに大量に出る。
    static func installQuietLogging() {
        _ = quietLoggingInstalled
    }

    private static let quietLoggingInstalled: Bool = {
        whisper_log_set(quietLog, nil)
        ggml_log_set(quietLog, nil)
        return true
    }()
}

/// 直前に転送したログが ERROR 以上だったか（`GGML_LOG_LEVEL_CONT` の続き行をそれに合わせる）。
private let lastLogForwarded = Atomic<Bool>(false)

private func quietLog(_ level: ggml_log_level, _ text: UnsafePointer<CChar>?, _: UnsafeMutableRawPointer?) {
    let forward: Bool
    if level == GGML_LOG_LEVEL_CONT {
        forward = lastLogForwarded.load(ordering: .relaxed)
    } else {
        forward = level.rawValue >= GGML_LOG_LEVEL_ERROR.rawValue
        lastLogForwarded.store(forward, ordering: .relaxed)
    }
    if forward, let text { fputs(text, stderr) }
}
