import Carbon.HIToolbox
import AutoNoteCore
import SwiftUI

/// ショートカット: the three global shortcuts. Recorded combos are written as `combo.description` to
/// `Settings.shortcuts`; the save re-registers them (`settingsSaved` → `HotKeyCenter.apply`) and a combo another app
/// holds is reported next to its field.
struct ShortcutsTab: View {
    let env: AppEnvironment

    @State private var shortcuts = Shortcuts()
    @State private var loaded = false
    @State private var saveState: SaveState = .idle
    /// `RegisterEventHotKey` failures from the last save.
    @State private var failures: [ShortcutAction: OSStatus] = [:]

    static let takenMessage = "このショートカットは他のアプリが使っています"

    private var bindings: ShortcutBindings { ShortcutBindings(shortcuts) }
    private var duplicates: [ShortcutAction] { bindings.duplicates() }

    private static func title(_ a: ShortcutAction) -> String {
        switch a {
        case .bookmark: "ブックマーク"
        case .toggleRecording: "録音開始・停止"
        case .togglePause: "一時停止・再開"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(ShortcutAction.allCases, id: \.self) { action in
                        LabeledContent(Self.title(action)) {
                            VStack(alignment: .trailing, spacing: 2) {
                                let raw = shortcuts[keyPath: action.keyPath]
                                ShortcutRecorderField(combo: bindings.combo(for: action),
                                                      placeholder: ShortcutBindings.unreadableMessage(raw)) { combo in
                                    shortcuts[keyPath: action.keyPath] = combo.description
                                    failures[action] = nil
                                    saveState = .idle
                                }
                                if duplicates.contains(action) {
                                    Text("ほかの操作と同じショートカットです").font(.caption).foregroundStyle(.red)
                                }
                                if let status = failures[action] {
                                    Text(status == OSStatus(eventHotKeyExistsErr) ? Self.takenMessage
                                         : "ショートカットを登録できません（\(status)）")
                                        .font(.caption).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("どのアプリを使っていても効きます。⌃ ⌥ ⌘ のどれかを含めてください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("既定に戻す") {
                        shortcuts = Shortcuts()
                        failures = [:]
                    }
                }
            }
            .formStyle(.grouped)
            SaveBar(state: saveState, disabled: !loaded || !duplicates.isEmpty) { save() }
        }
        .task {
            if let s = try? await env.settings.load() {
                shortcuts = s.shortcuts
                loaded = true
            } else {
                saveState = .failed("settings.json を読めません")
            }
        }
    }

    private func save() {
        let value = shortcuts
        // A combo that does not parse or lacks ⌃ ⌥ ⌘ never reaches settings.json from here.
        for action in ShortcutAction.allCases {
            guard let combo = ShortcutBindings(value).combo(for: action) else {
                saveState = .failed("\(Self.title(action)): \(ShortcutBindings.unreadableMessage(value[keyPath: action.keyPath]))")
                return
            }
            do { try combo.validate() } catch {
                saveState = .failed("\(Self.title(action)): \(SettingsSaving.message(error))")
                return
            }
        }
        Task {
            do {
                let (_, result) = try await SettingsSaving.save(env) { $0.shortcuts = value }
                failures = result.hotKeys.filter { $0.value != noErr }
                saveState = failures.isEmpty ? .saved : .failed("保存しましたが、使えないショートカットがあります")
            } catch {
                saveState = .failed(SettingsSaving.message(error))
            }
        }
    }
}
