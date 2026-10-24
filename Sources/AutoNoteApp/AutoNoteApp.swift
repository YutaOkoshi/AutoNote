import AVFoundation
import AutoNoteCore
import SwiftUI

@main
struct AutoNoteApp: App {
    var body: some Scene {
        MenuBarExtra("AutoNote", systemImage: "waveform") {
            Text("バージョン: \(AutoNoteVersion.current)")
            Divider()
            Button("マイク許可を確認") {
                checkMicrophonePermission()
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
