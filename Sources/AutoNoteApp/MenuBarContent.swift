import AVFoundation
import AppKit
import AutoNoteCore
import SwiftUI

/// The menu-bar label: `waveform` alone when idle (plan 00 E2E 7b reads that name); the state symbol and the elapsed
/// time while recording, paused or in the grace period.
struct MenuBarLabel: View {
    let shell: AppShell
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The label's `onAppear` never fires in a menu-bar extra, but its body is evaluated to draw the icon.
        let _ = shell.install(openWindow)
        content
    }

    @ViewBuilder private var content: some View {
        // No `TimelineView` here: `AppModel` already ticks `elapsedSeconds` once a second while recording, paused or in
        // the grace period, and a periodic timeline inside a menu-bar label re-entered SwiftUI's update pass without
        // end (main thread at 100 %, the window and accessibility frozen from 録音開始 until quit; found 2026-10-27).
        let p = shell.env.map { $0.model.menuBar(now: Date()) }
        if let p, let title = p.title {
            HStack(spacing: 4) {
                Image(systemName: p.symbol)
                Text(title).monospacedDigit()
            }
        } else {
            // Idle or countdown: `waveform` alone (plan 00 E2E 7b reads that name), or `hourglass` while a job runs.
            Image(systemName: p?.symbol ?? "waveform")
        }
    }
}

/// The menu: `model.menuBar(now:)`'s items in order (plan 06 Task 13 Step 6), with the plan 02 開発 menu after 設定…
/// (ruling X11, `scripts/tcc-check.sh` clicks it).
struct MenuBarContent: View {
    let shell: AppShell
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let model = shell.env?.model {
            ForEach(Array(model.menuBar(now: Date()).items.enumerated()), id: \.offset) { _, item in
                row(item, model: model)
            }
        } else {
            Text("起動中…")
            Divider()
            DevMenu()
            Button("終了") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    @ViewBuilder private func row(_ item: MenuItem, model: AppModel) -> some View {
        switch item {
        case .status(let line):
            Text(line)
        case .startRecording:
            Button("録音開始") { run(model, .start) }
        case .stop:
            Button("停止") { run(model, .stop) }
        case .pause:
            Button("一時停止") { run(model, .pause) }
        case .readinessIssue(_, let title):
            Text(title)
        case .resume:
            Button("再開") { run(model, .resume) }
        case .bookmark:
            Button("ブックマーク") { run(model, .bookmark(nil)) }
        case .cancelCountdown:
            Button("取り消す") { run(model, .cancelCountdown) }
        case .language(let current):
            Picker("言語", selection: Binding(get: { current }, set: { run(model, .setLanguage($0)) })) {
                Text("自動").tag(Language.auto)
                Text("日本語").tag(Language.ja)
                Text("英語").tag(Language.en)
            }
        case .minutesMissing(let id, let label):
            Button(label) { run(model, .notice(.retry(id))) }
        case .automationFailed(let name, let meetingID):
            Button("Automation 失敗: \(name)（再実行）") { run(model, .rerunAutomation(name: name, meetingID: meetingID)) }
        case .openWindow:
            Divider()
            Button("ウィンドウを開く") { shell.open(AppShell.mainWindowID) }
        case .openLatestMinutes(let enabled):
            Button("最新の議事録を開く") { run(model, .openLatestMinutes) }
                .disabled(!enabled)
        case .settings:
            Button("設定…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",")
            Divider()
            DevMenu()
        case .quit:
            Divider()
            Button("終了") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private func run(_ model: AppModel, _ action: UserAction) {
        Task { await model.perform(action) }
    }
}

// MARK: - 開発 (plan 02 Task 1)

/// The temporary TCC checks of plan 02 Task 1, kept for `scripts/tcc-check.sh` (ruling X11). The item titles are
/// what the script clicks.
private struct DevMenu: View {
    var body: some View {
        Menu("開発") {
            Button("マイク許可を確認") { Self.checkMicrophonePermission() }
            Button("システム音声を確認（15 秒）") {
                Task.detached { await DevChecks.checkSystemAudio(seconds: 15) }
            }
            Button("Dictation を確認（/tmp/autonote-dictation.aiff）") {
                Task.detached { await DevChecks.checkDictation(file: URL(filePath: "/tmp/autonote-dictation.aiff")) }
            }
        }
    }

    /// Prints the microphone TCC state and asks for it when undetermined.
    private static func checkMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        print("マイク許可の状態: \(describe(status))")
        guard status == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            print("マイク許可の要求結果: \(granted ? "authorized" : "denied")")
        }
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }
}

// MARK: - Windows

/// Launch item 4 (§11.6): shown once, until OK.
struct ConsentNoticeView: View {
    let shell: AppShell
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 16) {
            Text("録音は相手の同意を得て行ってください")
                .font(.headline)
                .multilineTextAlignment(.center)
            Button("OK") {
                shell.consentAccepted()
                dismissWindow(id: AppShell.consentWindowID)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(minWidth: 320)
    }
}
