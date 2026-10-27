import AppKit
import AutoNoteCore
import SwiftUI

/// The eight tabs of the settings window, in their order.
enum SettingsTab: Hashable {
    case general, devices, transcription, dictionary, minutes, automations, retention, shortcuts
}

/// The settings window (plan 06 Task 15): eight tabs. Each tab loads what it shows when it appears and writes it
/// with its own 「保存」.
struct SettingsView: View {
    let shell: AppShell

    var body: some View {
        if let env = shell.env {
            TabView {
                GeneralTab(env: env)
                    .tabItem { Label("一般", systemImage: "gearshape") }
                DevicesTab(env: env)
                    .tabItem { Label("機材", systemImage: "headphones") }
                TranscriptionTab(env: env)
                    .tabItem { Label("文字起こし", systemImage: "text.bubble") }
                DictionaryTab(env: env)
                    .tabItem { Label("辞書", systemImage: "character.book.closed") }
                MinutesTab(env: env)
                    .tabItem { Label("議事録", systemImage: "doc.text") }
                AutomationsTab(env: env)
                    .tabItem { Label("Automations", systemImage: "gearshape.2") }
                RetentionTab(env: env)
                    .tabItem { Label("保持", systemImage: "clock.arrow.circlepath") }
                ShortcutsTab(env: env)
                    .tabItem { Label("ショートカット", systemImage: "keyboard") }
            }
            .frame(minWidth: 700, idealWidth: 720, minHeight: 560, idealHeight: 620)
        } else {
            ProgressView("起動中…")
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}

/// Every settings save (brief Step 3): one `settings.change` (load → apply the tab's fields → `SettingsNormalizer`
/// → save, in one actor turn, so a concurrent write such as `ClaudeLocator.fillDefaultPath` is not undone) →
/// `env.settingsSaved(old:new:)`, which re-applies the hot keys, the login item and the queue inputs. A tab only
/// changes its own fields, so two open tabs never undo each other.
@MainActor
enum SettingsSaving {
    static func save(_ env: AppEnvironment, _ apply: @escaping @Sendable (inout AutoNoteCore.Settings) -> Void)
        async throws -> (saved: AutoNoteCore.Settings, result: AppEnvironment.SaveResult) {
        let (old, new) = try await env.settings.change { s in
            apply(&s)
            s = SettingsNormalizer.normalized(s)
        }
        let result = await env.settingsSaved(old: old, new: new)
        return (new, result)
    }

    static func message(_ error: any Error) -> String {
        switch error {
        case AppCommandError.invalid(let m), AppCommandError.failed(let m), AppCommandError.notFound(let m): m
        default: "保存できませんでした（\((error as NSError).localizedDescription)）"
        }
    }
}

/// The line next to a tab's 「保存」.
enum SaveState: Equatable {
    case idle, saved, failed(String)
}

struct SaveStateLabel: View {
    let state: SaveState

    var body: some View {
        switch state {
        case .idle: EmptyView()
        case .saved: Label("保存しました", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .failed(let m): Label(m, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }
}

/// 「保存」 on the right with its result on the left, at the bottom of a tab.
struct SaveBar: View {
    let state: SaveState
    var disabled = false
    let action: () -> Void

    var body: some View {
        HStack {
            SaveStateLabel(state: state)
            Spacer()
            Button("保存", action: action)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(disabled)
        }
        .padding([.horizontal, .bottom])
    }
}

/// An editable list row with a stable identity, so deleting a row never shifts another row's text field.
struct EditRow: Identifiable, Equatable {
    let id = UUID()
    var a: String
    var b: String = ""
}

extension View {
    /// Runs `body` when any window of the app becomes key (the settings window coming to the front, §7.2).
    func onWindowBecameKey(_ body: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in body() }
    }
}
