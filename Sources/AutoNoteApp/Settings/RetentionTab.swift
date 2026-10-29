import AutoNoteCore
import SwiftUI

/// 保持: how many days the recorded audio is kept (§12). `RetentionScheduler` reads the saved value.
struct RetentionTab: View {
    let env: AppEnvironment

    @State private var days = 30
    @State private var loaded = false
    @State private var saveState: SaveState = .idle

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("音声") {
                    LabeledContent("音声を残す日数") {
                        HStack(spacing: 4) {
                            TextField("日数", value: $days, format: .number)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                            Stepper("日数", value: $days, in: 0...3650).labelsHidden()
                            Text("日")
                        }
                    }
                    Text(days <= 0 ? "音声を削除しません" : "録音から \(days) 日を過ぎた音声を削除します。文字起こしと議事録は残ります。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("0 にすると削除しません。").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            SaveBar(state: saveState, disabled: !loaded) { save() }
        }
        .task {
            if let s = try? await env.settings.load() {
                days = s.audioRetentionDays
                loaded = true
            } else {
                saveState = .failed("settings.json を読めません")
            }
        }
    }

    private func save() {
        let value = days
        Task {
            do {
                let (saved, _) = try await SettingsSaving.save(env) { $0.audioRetentionDays = value }
                days = saved.audioRetentionDays
                saveState = .saved
            } catch {
                saveState = .failed(SettingsSaving.message(error))
            }
        }
    }
}
