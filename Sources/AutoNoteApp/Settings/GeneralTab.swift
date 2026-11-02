import AppKit
import AutoNoteCore
import ServiceManagement
import SwiftUI

/// 一般: 保存先 (the output folder), launch at login, how `claude` is launched (command, arguments, environment),
/// summarizer, CLI install line, what leaves the Mac.
struct GeneralTab: View {
    let env: AppEnvironment

    @State private var outputFolder = ""
    @State private var launchAtLogin = true
    @State private var claudePath = ""
    @State private var claudeLaunch = ClaudeLaunchDraft(AutoNoteCore.Settings())
    /// What is typed into the arguments field before Enter adds it as one token.
    @State private var argumentInput = ""
    @State private var claudeModel = ""
    @State private var summarizerKind: SummarizerKind = .claudeCode
    @State private var liveSummaryEnabled = false
    @State private var liveSummaryInterval = 20
    @State private var liveSummaryModel = ""
    @State private var loaded = false
    /// `launchAtLogin` as last loaded or saved, to tell whether a save changed the toggle.
    @State private var savedLaunchAtLogin = true
    @State private var saveState: SaveState = .idle
    @State private var loginItemMessage: String?
    @State private var loginItemNeedsApproval = false
    @State private var searchingClaude = false
    @State private var claudeSearchMessage: String?
    @State private var copied = false

    private var cliCommand: String {
        let cli = Bundle.main.bundleURL.appending(path: "Contents/MacOS/autonote").path(percentEncoded: false)
        return "sudo mkdir -p /usr/local/bin && sudo ln -sf \"\(cli)\" /usr/local/bin/autonote"
    }

    /// Where minutes go when the field is left empty (`FirstRunDefaults.defaultOutputFolder`), as the path string
    /// `outputFolder(forInput:)` saves (no trailing slash).
    private var defaultFolder: String {
        FirstRunDefaults.outputFolder(
            forInput: "", paths: env.paths, isDataDirectoryOverridden: env.isDataDirectoryOverridden)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("保存先") {
                    HStack {
                        TextField(
                            "保存先", text: $outputFolder,
                            prompt: Text(ReadinessPresentation.abbreviate(defaultFolder, home: NSHomeDirectory())))
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
                Section {
                    HStack {
                        TextField("コマンド", text: $claudePath, prompt: Text("/opt/homebrew/bin/claude"))
                        Button("探す") { findClaude() }.disabled(searchingClaude)
                    }
                    if let claudeSearchMessage {
                        Text(claudeSearchMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    argumentsEditor
                    environmentEditor
                } header: {
                    Text("Claude の起動")
                } footer: {
                    Text("引数は claude の既定の引数の後ろに付けます。環境変数は AutoNote が組み立てる PATH より優先します。引数は議事録の作成とリアルタイム要約に、環境変数はそれに加えてログインの確認にも使います。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Claude Code") {
                    TextField("モデル", text: $claudeModel, prompt: Text("空なら Claude Code の既定"))
                    Picker("要約器", selection: $summarizerKind) {
                        Text("Claude Code").tag(SummarizerKind.claudeCode)
                    }
                }
                Section("リアルタイム要約") {
                    Toggle("録音中に要約を表示する", isOn: $liveSummaryEnabled)
                    Stepper(value: $liveSummaryInterval, in: Settings.liveSummaryIntervalRange, step: 5) {
                        LabeledContent("更新間隔", value: "\(liveSummaryInterval) 秒")
                    }
                    TextField("モデル", text: $liveSummaryModel, prompt: Text(Settings.defaultLiveSummaryModel))
                    Text("オンにすると、録音中に確定した発話のテキストを更新間隔ごとに Claude Code へ送り、いまの話題・決定事項・宿題を録音画面に出します。議事録の作成と同じ Claude の利用枠を使います。")
                        .font(.caption).foregroundStyle(.secondary)
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
                    Text(PrivacyCopy.externalNotice).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            SaveBar(state: saveState, disabled: !loaded) { save() }
        }
        .task { await load() }
    }

    /// Tokens with × each, then a field that adds one token on Enter (spaces stay inside the token).
    private var argumentsEditor: some View {
        LabeledContent("引数") {
            VStack(alignment: .trailing, spacing: 6) {
                if !claudeLaunch.arguments.isEmpty {
                    FlowLayout {
                        ForEach(Array(claudeLaunch.arguments.enumerated()), id: \.offset) { index, argument in
                            ArgumentToken(text: argument) { claudeLaunch.arguments.remove(at: index) }
                        }
                    }
                }
                TextField("引数", text: $argumentInput, prompt: Text("引数を入れて Enter（例: --settings）"))
                    .labelsHidden()
                    .onSubmit { addArgument() }
            }
        }
    }

    /// Name = value rows, − on each row and + below.
    private var environmentEditor: some View {
        LabeledContent("環境変数") {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach($claudeLaunch.environment) { $row in
                    HStack {
                        TextField("名前", text: $row.name, prompt: Text("名前（例: CLAUDE_CONFIG_DIR）"))
                            .labelsHidden()
                            .frame(minWidth: 240)
                        Text("=").foregroundStyle(.secondary)
                        TextField("値", text: $row.value, prompt: Text("値")).labelsHidden()
                        Button("削除", systemImage: "minus.circle") {
                            claudeLaunch.environment.removeAll { $0.id == row.id }
                        }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                Button("環境変数を追加", systemImage: "plus") {
                    claudeLaunch.environment.append(.init(name: "", value: ""))
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }
    }

    private func addArgument() {
        guard let token = ClaudeLaunchDraft.token(argumentInput) else { return }
        claudeLaunch.arguments.append(token)
        argumentInput = ""
    }

    private func load() async {
        guard let s = try? await env.settings.load() else {
            saveState = .failed("settings.json を読めません")
            return
        }
        outputFolder = s.outputFolder ?? ""
        launchAtLogin = s.launchAtLogin
        claudePath = s.claudePath ?? ""
        claudeLaunch = ClaudeLaunchDraft(s)
        argumentInput = ""
        claudeModel = s.claudeModel ?? ""
        summarizerKind = s.summarizerKind
        liveSummaryEnabled = s.liveSummaryEnabled
        liveSummaryInterval = s.liveSummaryIntervalSeconds
        liveSummaryModel = s.liveSummaryModel
        savedLaunchAtLogin = s.launchAtLogin
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
        // Empty means the default folder, never nil. Whatever folder is saved is created here (with its parents) so
        // saving never leaves a 保存先 that does not exist; when it cannot be created nothing is saved.
        let folder = FirstRunDefaults.outputFolder(
            forInput: outputFolder, paths: env.paths, isDataDirectoryOverridden: env.isDataDirectoryOverridden)
        let path = Self.nilIfBlank(claudePath), model = Self.nilIfBlank(claudeModel)
        // Text left in the arguments field without Enter is still one argument.
        addArgument()
        let launch: (arguments: [String], environment: [String: String])
        do {
            launch = try claudeLaunch.validated()
        } catch {
            saveState = .failed(SettingsSaving.message(error))
            return
        }
        let claudeArgs = launch.arguments, claudeEnv = launch.environment
        let login = launchAtLogin, kind = summarizerKind
        let liveOn = liveSummaryEnabled, liveInterval = liveSummaryInterval
        let liveModel = Self.nilIfBlank(liveSummaryModel) ?? Settings.defaultLiveSummaryModel
        do {
            try FileManager.default.createDirectory(
                at: URL(filePath: folder, directoryHint: .isDirectory), withIntermediateDirectories: true)
        } catch {
            saveState = .failed("保存先を作れませんでした")
            return
        }
        Task {
            do {
                let (saved, result) = try await SettingsSaving.save(env) {
                    $0.outputFolder = folder
                    $0.launchAtLogin = login
                    $0.claudePath = path
                    $0.claudeArgs = claudeArgs
                    $0.claudeEnv = claudeEnv
                    $0.claudeModel = model
                    $0.summarizerKind = kind
                    $0.liveSummaryEnabled = liveOn
                    $0.liveSummaryIntervalSeconds = liveInterval
                    $0.liveSummaryModel = liveModel
                }
                outputFolder = saved.outputFolder ?? ""
                liveSummaryModel = saved.liveSummaryModel
                claudeLaunch = ClaudeLaunchDraft(saved)
                saveState = .saved
                let toggledOn = login && !savedLaunchAtLogin
                savedLaunchAtLogin = saved.launchAtLogin
                showLoginItemOutcome(result.loginItem, toggledOn: toggledOn)
            } catch {
                saveState = .failed(SettingsSaving.message(error))
            }
        }
    }

    /// System Settings opens only when this save itself turned the toggle on and `LoginItem.set` did not already
    /// open it; saving an unrelated field while macOS waits for approval just shows the message and the button.
    private func showLoginItemOutcome(_ outcome: LoginItem.Outcome, toggledOn: Bool) {
        switch outcome {
        case .unchanged, .updated:
            loginItemMessage = nil
            loginItemNeedsApproval = false
        case .leftAlone:
            showLoginItemStatus()
        case .requiresApproval(let opened):
            loginItemMessage = "macOS がログイン項目の許可を待っています"
            loginItemNeedsApproval = true
            if !opened && toggledOn { SMAppService.openSystemSettingsLoginItems() }
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

/// One argument of 「Claude の起動」 as a chip with its ×.
private struct ArgumentToken: View {
    let text: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.system(.callout, design: .monospaced)).lineLimit(1)
            Button("削除", systemImage: "xmark.circle.fill", action: remove)
                .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                .accessibilityLabel("引数 \(text) を削除")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }
}
