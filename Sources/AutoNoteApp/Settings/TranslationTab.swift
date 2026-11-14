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
            TranslationSettingsForm(
                mode: $mode, target: $target, modelName: $modelName, profile: profile, licenseAccepted: accepted,
                installed: installed, progress: progress, modelError: modelError, loaded: loaded,
                runtimeAvailable: env.translationRuntimeAvailable,
                onDownload: requestDownload, onDelete: delete,
                onReviewLicense: {
                    pendingDownload = nil
                    showLicense = true
                })
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
