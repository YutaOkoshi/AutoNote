import Foundation
import Synchronization

/// How `AppModel` reads the three readiness facts (output folder, transcription model, Claude Code) and acts on them.
public protocol ReadinessPort: Sendable {
    func current() async -> Readiness
    /// A new subscription on every call. The first value is the current model, then every change.
    func updates() async -> AsyncStream<Readiness.Model>
    func redetectClaude() async -> Readiness.Claude
    func retryModelDownload() async
    func installGuide() async
}

/// Passes a download fraction on only when its whole percent grows, so a per-chunk callback reaches the UI at most 101 times.
private final class PercentGate: Sendable {
    private let last: Mutex<Int>
    init(start: Int) { last = Mutex(start) }

    /// The fraction clamped to 0...1, or nil when it is not finite or its whole percent was already passed on.
    func admit(_ raw: Double) -> Double? {
        guard raw.isFinite else { return nil }
        let fraction = min(1, max(0, raw))
        let pct = Int(fraction * 100)
        let admitted = last.withLock { last -> Bool in
            guard pct > last else { return false }
            last = pct
            return true
        }
        return admitted ? fraction : nil
    }
}

public actor LiveReadinessPort: ReadinessPort {
    public static let firstRunModel = "base"
    /// Claude Code's official getting-started page, which carries the install steps.
    public static let installGuideURL = URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup")!

    private let settings: SettingsStore
    private let outputFolder: any OutputFolderPort
    private let models: ModelManager
    private let catalog: EngineCatalog
    private let opener: any FileOpener
    private let locate: @Sendable () async -> String?
    private let isExecutable: @Sendable (String) -> Bool

    private var downloading: (name: String, fraction: Double)?
    private var failure: (name: String, reason: String)?
    /// Bumped when a download starts or ends, so a model value computed across an await is not stale.
    private var generation = 0
    private var continuations: [UUID: AsyncStream<Readiness.Model>.Continuation] = [:]

    public init(settings: SettingsStore, outputFolder: any OutputFolderPort, models: ModelManager, catalog: EngineCatalog,
                opener: any FileOpener,
                locate: @escaping @Sendable () async -> String? = { await ClaudeLocator.locate() },
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.settings = settings
        self.outputFolder = outputFolder
        self.models = models
        self.catalog = catalog
        self.opener = opener
        self.locate = locate
        self.isExecutable = isExecutable
    }

    deinit {
        for continuation in continuations.values { continuation.finish() }
    }

    // MARK: - ReadinessPort

    public func current() async -> Readiness {
        let s = await loadSettings()
        let path = s.outputFolder ?? ""
        let available = path.isEmpty ? false : await outputFolder.isAvailable()
        let model = await modelValue()
        let claudePath = s.claudePath
        return Readiness(outputFolder: .init(path: path, available: available), model: model,
                         claude: .init(path: claudePath, found: claudePath.map(isExecutable) ?? false))
    }

    public func updates() async -> AsyncStream<Readiness.Model> {
        let initial = await modelValue()
        let (stream, continuation) = AsyncStream.makeStream(of: Readiness.Model.self, bufferingPolicy: .bufferingNewest(128))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        continuations[id] = continuation
        continuation.yield(initial)
        return stream
    }

    public func redetectClaude() async -> Readiness.Claude {
        if let found = await locate() {
            _ = try? await settings.update { $0.claudePath = found }
            return .init(path: found, found: true)
        }
        let stored = await loadSettings().claudePath
        return .init(path: stored, found: stored.map(isExecutable) ?? false)
    }

    public func retryModelDownload() async {
        start(failure?.name ?? Self.firstRunModel)
    }

    public func installGuide() async {
        await opener.open(Self.installGuideURL)
    }

    // MARK: - First run

    /// Starts the first-run model download when nothing is installed and the data folder is not overridden.
    /// Returns the model it started, or nil.
    public func startFirstRunDownload(isDataDirectoryOverridden: Bool) async -> String? {
        guard downloading == nil else { return nil }
        let installed = await models.installed().map(\.name)
        guard downloading == nil,
              let name = FirstRunDefaults.modelToDownload(installed: installed,
                                                          isDataDirectoryOverridden: isDataDirectoryOverridden)
        else { return nil }
        start(name)
        return name
    }

    public static func failureReason(_ error: any Error) -> String {
        if error is URLError { return "ネットワークにつながりませんでした" }
        if let e = error as? ModelError {
            switch e {
            case .checksumMismatch, .sizeMismatch: return "ダウンロードしたファイルが壊れていました"
            case .unknownModel: break
            }
        }
        return "ダウンロードが途中で止まりました"
    }

    // MARK: - Private

    private func start(_ name: String) {
        guard downloading == nil else { return }
        downloading = (name, 0)
        failure = nil
        generation += 1
        broadcast(.downloading(name, fraction: 0))

        let models = models
        let gate = PercentGate(start: 0)
        // Runs off the actor so `current()` stays responsive; `ModelManager` joins duplicate downloads.
        Task.detached { [weak self] in
            let (pipe, feed) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .unbounded)
            let relay = Task { [weak self] in
                for await fraction in pipe { await self?.progressed(name, fraction) }
            }
            let error: (any Error)?
            do {
                _ = try await models.download(name) { raw in
                    if let fraction = gate.admit(raw) { feed.yield(fraction) }
                }
                error = nil
            } catch let e {
                error = e
            }
            feed.finish()
            await relay.value
            await self?.finished(name, error: error)
        }
    }

    private func progressed(_ name: String, _ fraction: Double) {
        guard let d = downloading, d.name == name, fraction > d.fraction else { return }
        downloading = (name, fraction)
        broadcast(.downloading(name, fraction: fraction))
    }

    private func finished(_ name: String, error: (any Error)?) async {
        downloading = nil
        failure = error.map { (name, Self.failureReason($0)) }
        generation += 1
        broadcast(await modelValue())
    }

    /// Downloading, then the last failure, then what the batch engine resolves to.
    private func modelValue() async -> Readiness.Model {
        while true {
            if let d = downloading { return .downloading(d.name, fraction: d.fraction) }
            if let f = failure { return .failed(f.name, reason: f.reason) }
            let seen = generation
            let s = await loadSettings()
            let override = EngineChoice.fromSettings(kind: s.finalEngine, model: s.finalModel, role: .batch,
                                                     machine: catalog.machine)
            let choice = await catalog.resolve(role: .batch, language: s.defaultLanguage, override: override)
            guard seen == generation else { continue }
            if let choice, choice.kind == .whisper { return .installed(choice.model ?? "") }
            return .none
        }
    }

    private func loadSettings() async -> Settings {
        (try? await settings.load()) ?? Settings()
    }

    private func broadcast(_ model: Readiness.Model) {
        for continuation in continuations.values { continuation.yield(model) }
    }

    private func unsubscribe(_ id: UUID) { continuations[id] = nil }
}
