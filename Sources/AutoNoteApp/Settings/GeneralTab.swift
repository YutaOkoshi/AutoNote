import AppKit
import AutoNoteCore
import ServiceManagement
import SwiftUI

/// 一般: output folder, launch at login, `claude`, summarizer, CLI install line, what leaves the Mac.
struct GeneralTab: View {
    let env: AppEnvironment

    @State private var outputFolder = ""
    @State private var launchAtLogin = true
    @State private var claudePath = ""
    @State private var claudeModel = ""
    @State private var summarizerKind: SummarizerKind = .claudeCode
    @State private var loaded = false
    @State private var saveState: SaveState = .idle
    @State private var loginItemMessage: String?
    @State private var loginItemNeedsApproval = false
    @State private var searchingClaude = false
    @State private var claudeSearchMessage: String?
    @State private var copied = false

    static let externalNotice = "音声・文字起こし・議事録はこの Mac に保存します。外部へ送るのは、議事録を作るときに Claude Code へ渡す文字起こしテキスト（全文、辞書の用語、ブックマーク）だけで、音声は送りません。"

    private var cliCommand: String {
        let cli = Bundle.main.bundleURL.appending(path: "Contents/MacOS/autonote").path(percentEncoded: false)
        return "sudo mkdir -p /usr/local/bin && sudo ln -sf \"\(cli)\" /usr/local/bin/autonote"
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("出力フォルダ") {
                    HStack {
                        TextField("出力フォルダ", text: $outputFolder, prompt: Text("未設定"))
                            .labelsHidden()
                        Button("選ぶ…") { pickFolder() }
                    }
                    Text("議事録の Markdown と、辞書・プロンプト・機材登録の入った _autonote/ をここに置きます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("起動") {
                    Toggle("ログイン時に起動", isOn: $launchAtLogin)
                    if let loginItemMessage {
                        Text(loginItemMessage).font(.caption).foregroundStyle(loginItemNeedsApproval ? .orange : .red)
                    }
                    if loginItemNeedsApproval {
                        Button("システム設定で許可してください") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Section("Claude Code") {
                    HStack {
                        TextField("claude のパス", text: $claudePath, prompt: Text("/opt/homebrew/bin/claude"))
                        Button("探す") { findClaude() }.disabled(searchingClaude)
                    }
                    if let claudeSearchMessage {
                        Text(claudeSearchMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("モデル", text: $claudeModel, prompt: Text("空なら Claude Code の既定"))
                    Picker("要約器", selection: $summarizerKind) {
                        Text("Claude Code").tag(SummarizerKind.claudeCode)
                    }
                }
                Section("コマンドライン（autonote）") {
                    Text(cliCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        Button("コピー") { copyCLI() }
                        if copied { Text("コピーしました").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("ターミナルに貼り付けて実行すると autonote コマンドが使えるようになります。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("外部送信") {
                    Text(Self.externalNotice).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            SaveBar(state: saveState, disabled: !loaded) { save() }
        }
        .task { await load() }
    }

    private func load() async {
        guard let s = try? await env.settings.load() else {
            saveState = .failed("settings.json を読めません")
            return
        }
        outputFolder = s.outputFolder ?? ""
        launchAtLogin = s.launchAtLogin
        claudePath = s.claudePath ?? ""
        claudeModel = s.claudeModel ?? ""
        summarizerKind = s.summarizerKind
        loaded = true
        showLoginItemStatus()
    }

    /// What the system says right now, before anything is saved.
    private func showLoginItemStatus() {
        guard !env.isDataDirectoryOverridden else {
            loginItemMessage = "開発用のデータフォルダ（AUTONOTE_DATA_DIR）で動いているため、ログイン項目は変更しません"
            loginItemNeedsApproval = false
            return
        }
        loginItemNeedsApproval = launchAtLogin && LoginItem.status == .requiresApproval
        loginItemMessage = loginItemNeedsApproval ? "macOS がログイン項目の許可を待っています" : nil
    }

    private func save() {
        let folder = Self.nilIfBlank(outputFolder), path = Self.nilIfBlank(claudePath), model = Self.nilIfBlank(claudeModel)
        let login = launchAtLogin, kind = summarizerKind
        Task {
            do {
                let (saved, result) = try await SettingsSaving.save(env) {
                    $0.outputFolder = folder
                    $0.launchAtLogin = login
                    $0.claudePath = path
                    $0.claudeModel = model
                    $0.summarizerKind = kind
                }
                outputFolder = saved.outputFolder ?? ""
                saveState = .saved
                showLoginItemOutcome(result.loginItem, turnedOn: login)
            } catch {
                saveState = .failed(SettingsSaving.message(error))
            }
        }
    }

    private func showLoginItemOutcome(_ outcome: LoginItem.Outcome, turnedOn: Bool) {
        switch outcome {
        case .unchanged, .updated:
            loginItemMessage = nil
            loginItemNeedsApproval = false
        case .leftAlone:
            showLoginItemStatus()
        case .requiresApproval(let opened):
            loginItemMessage = "macOS がログイン項目の許可を待っています"
            loginItemNeedsApproval = true
            if !opened && turnedOn { SMAppService.openSystemSettingsLoginItems() }
        case .failed(let m):
            loginItemMessage = m
            loginItemNeedsApproval = false
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "選ぶ"
        if !outputFolder.isEmpty { panel.directoryURL = URL(filePath: outputFolder) }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputFolder = url.path(percentEncoded: false).replacing(/\/+$/, with: "")
    }

    private func findClaude() {
        searchingClaude = true
        claudeSearchMessage = "探しています…"
        Task {
            let found = await ClaudeLocator.locate()
            searchingClaude = false
            if let found {
                claudePath = found
                claudeSearchMessage = "見つかりました（保存すると使います）"
            } else {
                claudeSearchMessage = "claude が見つかりませんでした。パスを入れてください"
            }
        }
    }

    private func copyCLI() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cliCommand, forType: .string)
        copied = true
    }

    static func nilIfBlank(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
