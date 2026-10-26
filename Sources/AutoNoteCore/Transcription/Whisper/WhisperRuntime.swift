import whisper

/// whisper.cpp（XCFramework）への最小限の窓口。`import whisper` は AutoNoteCore の中だけで行う。
enum WhisperRuntime {
    /// whisper.cpp が報告する CPU/GPU 機能の一覧（例: `AVX = 1 | ...`）。
    static func systemInfo() -> String {
        String(cString: whisper_print_system_info())
    }

    /// 言語コード（`ja`・`en` など）の whisper 内部 ID。未知のコードは -1。
    static func languageID(_ code: String) -> Int32 {
        whisper_lang_id(code)
    }
}
