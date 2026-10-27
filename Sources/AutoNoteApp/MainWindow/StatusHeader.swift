import AppKit
import AutoNoteCore
import SwiftUI

/// The bands above the detail column (§5.3, §9.5): the recording state with the elapsed time whatever is selected,
/// the grace countdown, the disk warning, the output folder, the last error and the notices that need an answer.
struct StatusHeader: View {
    let env: AppEnvironment
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    /// Nil until the settings were read; then whether `outputFolder` is set (ruling X35).
    @State private var outputFolderConfigured: Bool?

    var body: some View {
        VStack(spacing: 0) {
            recordingBand
            if let warning = model.diskWarning {
                Band(systemImage: "externaldrive.badge.exclamationmark", tint: .orange) { Text(warning) }
            }
            if !model.outputFolderAvailable, let configured = outputFolderConfigured {
                Band(systemImage: "folder.badge.questionmark", tint: .orange) {
                    Text(configured ? "出力フォルダが見つかりません" : "出力フォルダが未設定です")
                    Spacer()
                    Button("設定を開く") {
                        NSApp.activate(ignoringOtherApps: true)
                        openSettings()
                    }
                }
            }
            if let error = model.lastError {
                Band(systemImage: "exclamationmark.circle", tint: .red) { Text(error) }
            }
            ForEach(model.prompts, id: \.id) { notice in
                promptBand(NoticeContent.make(notice))
            }
        }
        // Re-read whenever availability flips: setting or clearing the folder in Settings flips it within 30 s.
        .task(id: model.outputFolderAvailable) {
            let folder = (try? await env.settings.load())?.outputFolder
            outputFolderConfigured = !(folder ?? "").isEmpty
        }
    }

    @ViewBuilder private var recordingBand: some View {
        let state = model.recorder.state
        if [.recording, .paused, .grace].contains(state) {
            // Ticks every second for the grace countdown (ruling X21: the per-second line from `menuBar(now:)`).
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let r = model.recorder
                Band(systemImage: state == .paused ? "pause.circle.fill" : "record.circle", tint: state == .paused ? .secondary : .red) {
                    Text(state == .paused ? "一時停止中" : "録音中").bold()
                    if r.state == .recording, r.meetingID == nil {
                        Text("開始中…")
                    } else if let seconds = model.elapsedSeconds {
                        Text(MenuBarPresentation.clock(seconds)).monospacedDigit()
                    }
                    if state == .grace, let line = Self.statusLine(model.menuBar(now: context.date)) {
                        Text(line).foregroundStyle(.orange)
                    } else if state != .grace, let banner = r.banner {
                        Text(banner).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private func promptBand(_ content: NoticeContent) -> some View {
        Band(systemImage: "questionmark.bubble", tint: .accentColor) {
            Text(content.body)
            Spacer()
            ForEach(content.buttons, id: \.id) { button in
                Button(button.title) {
                    guard let action = NoticeContent.action(category: content.category, buttonID: button.id,
                                                            userInfo: content.userInfo) else { return }
                    Task { await model.perform(.notice(action)) }
                }
            }
        }
    }

    private static func statusLine(_ p: MenuBarPresentation) -> String? {
        for item in p.items { if case .status(let line) = item { return line } }
        return nil
    }
}

/// One full-width band.
struct Band<Content: View>: View {
    let systemImage: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}
