import AutoNoteCore
import SwiftUI

/// 文字起こし: engines and models for live and final transcription (§6.2), whisper model downloads, language,
/// echo cancellation (§5.6) and filler removal (§6.5).
struct TranscriptionTab: View {
    let env: AppEnvironment

    @State private var language: Language = .ja
    @State private var live: EngineChoice?
    @State private var final: EngineChoice?
    @State private var liveEntries: [EngineEntry] = []
    @State private var finalEntries: [EngineEntry] = []
    @State private var liveDefault: EngineChoice?
    @State private var finalDefault: EngineChoice?
    @State private var voiceProcessing = false
    @State private var fillerRemoval = true
    @State private var installed: Set<String> = []
    @State private var progress: [String: Double] = [:]
    @State private var modelError: String?
    @State private var loaded = false
    @State private var saveState: SaveState = .idle

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("言語") {
                    Picker("既定の言語", selection: $language) {
                        Text("自動").tag(Language.auto)
                        Text("日本語").tag(Language.ja)
                        Text("英語").tag(Language.en)
                    }
                    .onChange(of: language) { Task { await refreshEntries() } }
                }
                Section("リアルタイム") {
                    EnginePicker(title: "エンジン", selection: $live, entries: liveEntries, fallback: liveDefault)
                    missingModelNote(live)
                }
                Section("確定版") {
                    EnginePicker(title: "エンジン", selection: $final, entries: finalEntries, fallback: finalDefault)
                    missingModelNote(final)
                }
                Section("whisper のモデル") {
                    ForEach(WhisperModelCatalog.all, id: \.name) { model in
                        modelRow(model)
                    }
                    if let modelError { Text(modelError).font(.caption).foregroundStyle(.red) }
                    Text("ダウンロードしていないモデルは選べません。使う前にここでダウンロードしてください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("音声") {
                    Toggle("エコー除去", isOn: $voiceProcessing)
                    Text("他のアプリの音が小さくなることがあります。次回の起動から効きます")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("フィラー（えー、あのー など）を取り除く", isOn: $fillerRemoval)
                }
            }
            .formStyle(.grouped)
            SaveBar(state: saveState, disabled: !loaded) { save() }
        }
        .task { await load() }
    }

    @ViewBuilder private func missingModelNote(_ choice: EngineChoice?) -> some View {
        if let choice, choice.kind == .whisper, let model = choice.model, !installed.contains(model) {
            Text("whisper \(model) はまだダウンロードしていません。下でダウンロードするまで既定のエンジンを使います")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private func modelRow(_ model: WhisperModel) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(model.name)
                Text(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = progress[model.name] {
                ProgressView(value: p).frame(width: 140)
                Text("\(Int(p * 100))%").monospacedDigit().font(.caption)
            } else if installed.contains(model.name) {
                Text("ダウンロード済み").font(.caption).foregroundStyle(.secondary)
                Button("削除") { delete(model.name) }
            } else {
                Button("ダウンロード") { download(model.name) }
            }
        }
    }

    private func load() async {
        guard let s = try? await env.settings.load() else {
            saveState = .failed("settings.json を読めません")
            return
        }
        language = s.defaultLanguage
        let machine = env.catalog.machine
        live = EngineChoice.fromSettings(kind: s.liveEngine, model: s.liveModel, role: .live, machine: machine)
        final = EngineChoice.fromSettings(kind: s.finalEngine, model: s.finalModel, role: .batch, machine: machine)
        voiceProcessing = s.voiceProcessing
        fillerRemoval = s.fillerRemoval
        await refreshEntries()
        loaded = true
    }

    private func refreshEntries() async {
        installed = Set(await env.models.installed().map(\.name))
        liveEntries = await env.catalog.entries(role: .live, language: language)
        finalEntries = await env.catalog.entries(role: .batch, language: language)
        liveDefault = await env.catalog.resolve(role: .live, language: language, override: nil)
        finalDefault = await env.catalog.resolve(role: .batch, language: language, override: nil)
    }

    private func download(_ name: String) {
        progress[name] = 0
        modelError = nil
        Task {
            do {
                _ = try await env.models.download(name) { value in
                    Task { @MainActor in
                        if progress[name] != nil { progress[name] = value }
                    }
                }
            } catch {
                modelError = "\(name) をダウンロードできませんでした（\(String(describing: error))）"
            }
            progress[name] = nil
            await refreshEntries()
        }
    }

    private func delete(_ name: String) {
        Task {
            do {
                try await env.models.delete(name)
                modelError = nil
            } catch {
                modelError = "\(name) を削除できませんでした（\(String(describing: error))）"
            }
            await refreshEntries()
        }
    }

    private func save() {
        let lang = language, live = live, final = final, voice = voiceProcessing, filler = fillerRemoval
        Task {
            do {
                _ = try await SettingsSaving.save(env) {
                    $0.defaultLanguage = lang
                    $0.liveEngine = live?.kind.rawValue
                    $0.liveModel = live?.model
                    $0.finalEngine = final?.kind.rawValue
                    $0.finalModel = final?.model
                    $0.voiceProcessing = voice
                    $0.fillerRemoval = filler
                }
                saveState = .saved
            } catch {
                saveState = .failed(SettingsSaving.message(error))
            }
        }
    }
}

/// `nil` is 「既定」 (what `EngineCatalog.resolve` picks with no override). An unavailable entry is shown with its
/// reason and cannot be picked (§6.2).
private struct EnginePicker: View {
    let title: String
    @Binding var selection: EngineChoice?
    let entries: [EngineEntry]
    let fallback: EngineChoice?

    private static func name(_ c: EngineChoice) -> String {
        switch c.kind {
        case .dictation: "Apple 音声入力（DictationTranscriber）"
        case .speech: "Apple SpeechTranscriber"
        case .whisper: "whisper \(c.model ?? "")"
        }
    }

    var body: some View {
        Picker(title, selection: $selection) {
            Text("既定（\(fallback.map(Self.name) ?? "使えるエンジンがありません")）").tag(EngineChoice?.none)
            ForEach(entries, id: \.choice) { entry in
                Text(entry.available ? Self.name(entry.choice) : "\(Self.name(entry.choice)) — \(entry.reason ?? "使えません")")
                    .tag(EngineChoice?.some(entry.choice))
                    .disabled(!entry.available && entry.choice != selection)
            }
            // A saved choice that is not in the list any more stays visible instead of being silently replaced.
            if let selection, !entries.contains(where: { $0.choice == selection }) {
                Text("\(Self.name(selection))（使えません）").tag(EngineChoice?.some(selection))
            }
        }
        .pickerStyle(.radioGroup)
    }
}
