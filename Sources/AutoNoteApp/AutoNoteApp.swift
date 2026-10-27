import AVFoundation
import AutoNoteCore
import SwiftUI

@main
struct AutoNoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("AutoNote", systemImage: "waveform") {
            Text("バージョン: \(AutoNoteVersion.current)")
            Divider()
            // 一時的な開発メニュー（計画 02 Task 1 の TCC 確認用。計画 06 の Task 13 で削除する）
            Menu("開発") {
                Button("マイク許可を確認") {
                    checkMicrophonePermission()
                }
                Button("システム音声を確認（15 秒）") {
                    Task.detached { await DevChecks.checkSystemAudio(seconds: 15) }
                }
                Button("Dictation を確認（/tmp/autonote-dictation.aiff）") {
                    Task.detached { await DevChecks.checkDictation(file: URL(filePath: "/tmp/autonote-dictation.aiff")) }
                }
            }
            Divider()
            Button("終了") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    /// スパイク: マイクの TCC 許可状態を標準出力に出し、未決定なら許可を求める。
    private func checkMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        print("マイク許可の状態: \(describe(status))")
        guard status == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            print("マイク許可の要求結果: \(granted ? "authorized" : "denied")")
        }
    }

    private func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }
}
