import AppKit
import AVFoundation
import AutoNoteCore
import SwiftUI

/// The bands above the detail column (§5.3, §9.5): the recording state with the elapsed time whatever is selected,
/// the grace countdown and input meter, the green 「録音を保存しました」 band, the disk warning, the readiness bands
/// (only once there are meetings; the empty state shows the card instead), the last error and the notices that
/// need an answer.
struct StatusHeader: View {
    let env: AppEnvironment
    let model: AppModel
    let shell: AppShell
    /// The capture microphone's name, read once when recording starts; nil hides it.
    @State private var micName: String?

    var body: some View {
        VStack(spacing: 0) {
            if let stopped = model.stoppedBand {
                Band(systemImage: "checkmark.circle.fill", tint: .green) {
                    Text(ProcessingPresentation.stoppedBand(seconds: stopped.seconds))
                    Spacer()
                }
            }
            recordingBand
            if let warning = model.diskWarning {
                Band(systemImage: "externaldrive.badge.exclamationmark", tint: .orange) { Text(warning) }
            }
            if !model.meetings.isEmpty {
                ForEach(ReadinessPresentation.bands(model.readiness, home: NSHomeDirectory()), id: \.item) { row in
                    let isModel = row.item == .model
                    Band(systemImage: isModel ? "arrow.down.circle" : "exclamationmark.triangle",
                         tint: isModel ? .secondary : .orange) {
                        Text(row.band)
                        Spacer()
                        ForEach(row.actions, id: \.self) { action in
                            ReadinessActionButton(action: action, model: model, shell: shell)
                        }
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
        .onChange(of: model.recorder.state, initial: true) { _, new in
            // Once per recording (or when the window opens mid-recording); pause and grace keep the name.
            if new == .recording, micName == nil {
                micName = AVCaptureDevice.default(for: .audio)?.localizedName
            } else if new == .idle || new == .countdown {
                micName = nil
            }
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
                    LevelMeter(bars: model.inputLevel?.bars ?? 0)
                    if model.inputLevel?.quiet == true {
                        Text("音を拾えていません").foregroundStyle(.orange)
                    }
                    if let micName {
                        Text(micName).foregroundStyle(.secondary).lineLimit(1)
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
