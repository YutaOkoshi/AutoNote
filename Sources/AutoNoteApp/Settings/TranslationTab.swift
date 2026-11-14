import AppKit
import AutoNoteCore
import SwiftUI

/// 翻訳: when and into what to translate transcripts, the PLaMo 3 Translate models (download, delete, size, the
/// default for this Mac), and the license. Nothing is downloaded until the license is accepted (spec 1, 2).
struct TranslationTab: View {
    let env: AppEnvironment

    @State private var mode: TranslationMode = .off
    @State private var target: TranslationTarget = .auto
    @State private var modelName: String?
    @State private var licenseVersion: String?
    @State private var profile = MachineProfile.current()
    @State private var installed: Set<String> = []
    @State private var progress: [String: Double] = [:]
    @State private var modelError: String?
    @State private var loaded = false
    @State private var saveState: SaveState = .idle
    /// The model to download once the license is accepted in the sheet.
    @State private var pendingDownload: String?
    @State private var showLicense = false

    private var accepted: Bool { licenseVersion == TranslationLicense.version }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("翻訳") {
                    Picker("訳すタイミング", selection: $mode) {
                        ForEach(TranslationSettingsPresentation.modes(profile: profile), id: \.mode) { option in
                            Text(option.disabledReason.map { "\(option.title) — \($0)" } ?? option.title)
                                .tag(option.mode)
                                .disabled(option.disabledReason != nil && option.mode != mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    Picker("訳す先", selection: $target) {
                        ForEach(TranslationTarget.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Text("自動では、日本語の発話を英語に、英語の発話を日本語に訳します。訳文は文字起こしの各行に併記します（会議の画面の「訳文」で表示を切り替えられます）。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !env.translationRuntimeAvailable {
                        Label(TranslationSettingsPresentation.runtimeUnavailableNote, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("モデル（PLaMo 3 Translate）") {
                    Picker("使うモデル", selection: $modelName) {
                        Text("この Mac の既定（\(TranslationModelPolicy.defaultModel(for: profile).displayName)）")
                            .tag(String?.none)
                        ForEach(TranslationSettingsPresentation.models(profile: profile), id: \.model.name) { row in
                            Text(row.disabledReason.map { "\(row.model.displayName) — \($0)" } ?? row.model.displayName)
                                .tag(String?.some(row.model.name))
                                .disabled(row.disabledReason != nil && row.model.name != modelName)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    ForEach(TranslationSettingsPresentation.models(profile: profile), id: \.model.name) { row in
                        modelRow(row)
                    }
                    if let modelError { Text(modelError).font(.caption).foregroundStyle(.red) }
                    if missingSelectedModel {
                        Text("\(selectedModel.displayName) はまだダウンロードしていません。ダウンロードするまで翻訳はできません")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("ライセンス") {
                    licenseSection
                }
            }
            .formStyle(.grouped)
            SaveBar(state: saveState, disabled: !loaded) { save() }
        }
        .task { await load() }
        .sheet(isPresented: $showLicense) {
            LicenseConsentSheet(downloading: pendingDownload.flatMap(TranslationModelCatalog.model(named:))) { agreed in
                showLicense = false
                let name = pendingDownload
                pendingDownload = nil
                guard agreed else { return }
                Task {
                    await accept()
                    if let name { download(name) }
                }
            }
        }
    }

    private var selectedModel: TranslationModel {
        TranslationModelPolicy.resolveModel(setting: modelName, profile: profile)
    }

    private var missingSelectedModel: Bool { loaded && !installed.contains(selectedModel.name) }

    @ViewBuilder private func modelRow(_ row: TranslationSettingsPresentation.ModelRow) -> some View {
        let name = row.model.name
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                Text(row.disabledReason ?? row.note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = progress[name] {
                ProgressView(value: p).frame(width: 120)
                Text("\(Int(p * 100))%").monospacedDigit().font(.caption)
            } else if installed.contains(name) {
                Text("ダウンロード済み").font(.caption).foregroundStyle(.secondary)
                Button("削除") { delete(name) }
            } else {
                Button("ダウンロード") { requestDownload(name) }
                    .disabled(row.disabledReason != nil)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var licenseSection: some View {
        Text(TranslationLicense.builtWith).font(.headline)
            .accessibilityIdentifier("translation-built-with")
        Text("モデルの重みには PLaMo Community License が適用されます。業務（社内利用を含む）で使う場合は PFN への事前登録が必要です（直近の売上 10 億円以下は無料、超える場合は別途契約）。")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Link("ライセンス本文", destination: TranslationLicense.licenseURL)
            Link("業務利用の登録フォーム", destination: TranslationLicense.registrationURL)
        }
        .font(.caption)
        if accepted {
            Label("同意済み（\(TranslationLicense.version) 版）", systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Button("ライセンスを確認して同意する…") {
                pendingDownload = nil
                showLicense = true
            }
        }
        Text(TranslationSettingsPresentation.privacyNote).font(.caption).foregroundStyle(.secondary)
    }

    private func load() async {
        guard let s = try? await env.settings.load() else {
            saveState = .failed("settings.json を読めません")
            return
        }
        mode = s.translationMode
        target = s.translationTarget
        modelName = s.translationModel
        licenseVersion = s.translationLicenseVersion
        await refreshInstalled()
        loaded = true
    }

    private func refreshInstalled() async {
        installed = Set(await env.translationModels.installed().map(\.name))
        await env.model.refresh()
    }

    /// The first download asks for the license (spec 2); later ones go straight ahead.
    private func requestDownload(_ name: String) {
        guard accepted else {
            pendingDownload = name
            showLicense = true
            return
        }
        download(name)
    }

    /// Saves the acceptance on its own (the rest of the tab keeps its unsaved edits).
    private func accept() async {
        do {
            _ = try await env.settings.change { $0.translationLicenseVersion = TranslationLicense.version }
            licenseVersion = TranslationLicense.version
        } catch {
            modelError = "同意を保存できませんでした（\(SettingsSaving.message(error))）"
        }
    }

    private func download(_ name: String) {
        progress[name] = 0
        modelError = nil
        Task {
            do {
                _ = try await env.translationModels.download(name) { value in
                    Task { @MainActor in
                        if progress[name] != nil { progress[name] = value }
                    }
                }
            } catch let e as TranslationError {
                modelError = e.message
            } catch {
                modelError = "\(name) をダウンロードできませんでした（\(String(describing: error))）"
            }
            progress[name] = nil
            await refreshInstalled()
        }
    }

    private func delete(_ name: String) {
        Task {
            do {
                try await env.translationModels.delete(name)
                modelError = nil
            } catch {
                modelError = "\(name) を削除できませんでした（\(String(describing: error))）"
            }
            await refreshInstalled()
        }
    }

    private func save() {
        let mode = mode, target = target, model = modelName
        Task {
            do {
                _ = try await SettingsSaving.save(env) {
                    $0.translationMode = mode
                    $0.translationTarget = target
                    $0.translationModel = model
                }
                saveState = .saved
            } catch {
                saveState = .failed(SettingsSaving.message(error))
            }
        }
    }
}

/// Shown before the first model download (and from the license section): what the license asks, the links, and
/// 「Built with PLaMo」. Only 「同意する」 saves the acceptance.
struct LicenseConsentSheet: View {
    let downloading: TranslationModel?
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TranslationLicense.title).font(.title3.bold())
            if let downloading {
                Text("\(downloading.displayName)（\(ByteCountFormatter.string(fromByteCount: downloading.sizeBytes, countStyle: .file))）をダウンロードする前に、ライセンスを確認してください。")
                    .font(.callout)
            }
            ForEach(Array(TranslationLicense.summary.enumerated()), id: \.offset) { _, line in
                Label { Text(line).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "circle.fill").font(.system(size: 5)) }
                    .font(.callout)
            }
            HStack(spacing: 16) {
                Link("ライセンス本文（PLaMo Community License）", destination: TranslationLicense.licenseURL)
                Link("業務利用の登録フォーム", destination: TranslationLicense.registrationURL)
            }
            .font(.callout)
            Text(TranslationLicense.builtWith).font(.headline).padding(.top, 4)
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { done(false) }
                    .keyboardShortcut(.cancelAction)
                Button(downloading == nil ? "同意する" : "同意してダウンロード") { done(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
