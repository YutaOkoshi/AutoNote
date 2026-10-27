import AppKit
import AutoNoteCore
import Foundation
import os

private let logger = Logger(subsystem: AppIdentity.bundleID, category: "AppEnvironment")

/// Every long-lived service of the running app, built in the order of plan 06 Task 13 Step 5. The decisions live in
/// Core (`AppWiring`, `LiveTranscriptionWiring`, the adapters); this type only creates the concrete services and
/// hands them to each other.
@MainActor
final class AppEnvironment {
    let environment: [String: String]
    let paths: AppPaths
    let settings: SettingsStore
    let manifests: ManifestStore
    let output: OutputFolderServices
    let session: RecordingSession
    let coordinator: AutoRecordCoordinator
    let registry: DeviceRegistry
    let monitor: DeviceMonitor
    let queue: QueueHolder
    let wiring: AppWiring
    let live: LiveTranscriptionWiring
    let crashRecovery: CrashRecovery
    let catalog: EngineCatalog
    let models: ModelManager
    let automationsFile: AutomationsFile
    let retention: Retention
    let retentionScheduler: RetentionScheduler
    let ports: AppPorts
    let model: AppModel
    let notifier: SystemUserNotifier
    let server: SocketServer

    private let routing: NoticeRouting

    /// A plain notification tap with no meeting, and `.openMeeting` taps. AppDelegate points this at the main window.
    var openWindow: @MainActor () -> Void {
        get { routing.openWindow }
        set { routing.openWindow = newValue }
    }

    /// Called by `settingsSaved` with the saved shortcuts. AppDelegate points this at `HotKeyCenter.apply`, whose
    /// per-action `RegisterEventHotKey` status comes back to the settings screen.
    var shortcutsChanged: @MainActor (Shortcuts) -> [ShortcutAction: OSStatus] = { _ in [:] }

    /// True when `AUTONOTE_DATA_DIR` is set (E2E / development): the login item is left alone (ruling X22).
    var isDataDirectoryOverridden: Bool { AppIdentity.isDataDirectoryOverridden(environment) }

    private init(environment: [String: String], paths: AppPaths, settings: SettingsStore, manifests: ManifestStore,
                 output: OutputFolderServices, session: RecordingSession, coordinator: AutoRecordCoordinator,
                 registry: DeviceRegistry, monitor: DeviceMonitor, queue: QueueHolder, wiring: AppWiring,
                 live: LiveTranscriptionWiring, crashRecovery: CrashRecovery, catalog: EngineCatalog, models: ModelManager,
                 automationsFile: AutomationsFile, retention: Retention, retentionScheduler: RetentionScheduler,
                 ports: AppPorts, model: AppModel, notifier: SystemUserNotifier, server: SocketServer, routing: NoticeRouting) {
        self.environment = environment
        self.paths = paths
        self.settings = settings
        self.manifests = manifests
        self.output = output
        self.session = session
        self.coordinator = coordinator
        self.registry = registry
        self.monitor = monitor
        self.queue = queue
        self.wiring = wiring
        self.live = live
        self.crashRecovery = crashRecovery
        self.catalog = catalog
        self.models = models
        self.automationsFile = automationsFile
        self.retention = retention
        self.retentionScheduler = retentionScheduler
        self.ports = ports
        self.model = model
        self.notifier = notifier
        self.server = server
        self.routing = routing
    }

    /// `notifier` is created by AppDelegate before any `await` (M9); its callbacks are bound here.
    static func make(environment: [String: String], notifier: SystemUserNotifier) async throws -> AppEnvironment {
        // 1. Paths, settings, manifests.
        let paths = AppPaths.resolve(environment: environment)
        try paths.createBaseDirectories()
        let settings = SettingsStore(paths: paths)
        let s = try await settings.load()
        let manifests = ManifestStore(paths: paths)

        // 2. Output-folder services; `rebuild` syncs the portable files (§8b (4)). A failed sync is logged and the
        //    launch goes on: `rebuild` switches the services before it syncs, so they are usable either way.
        let output = OutputFolderServices(paths: paths)
        do {
            try await output.rebuild(outputFolder: s.outputFolder)
        } catch {
            logger.error("output folder sync failed at launch (\(String(describing: error), privacy: .public))")
        }

        // 3. Recording session (default clock).
        let session = RecordingSession.live(paths: paths, settings: s)

        // 4. Engines.
        let machine = MachineKind.current()
        let models = ModelManager(directory: paths.modelsDirectory)
        let catalog = EngineCatalog(machine: machine, speech: AppleSpeechCapabilities(),
                                    installedModels: { await models.installed().map(\.name) })
        let factory = TranscriberFactory(models: models, machine: machine)

        // 5. Live transcription. The meeting's own language picks the engine (ruling X27); plan 04's signature stays.
        let live = LiveTranscriptionWiring(audio: { await session.audio(for: $0) }, makeFeed: { id in
            let language = try await manifests.load(id).language
            var current = try await settings.load()
            current.defaultLanguage = language
            let dictionary = await Self.dictionary(output)
            let feed = try await LiveFeed.make(settings: current, catalog: catalog, factory: factory, dictionary: dictionary,
                                               liveJSON: paths.transcriptFile(id, .live))
            return LiveFeedStart(feed: feed, language: language, hints: dictionary.terms)
        })

        // 6. Notifier and automations. The notifier's callbacks reach the model through `routing` (built below).
        let routing = NoticeRouting()
        notifier.bind(SystemUserNotifier.Handlers(
            onAction: { [routing] action, _ in routing.handle(action) },
            onPost: { [routing] notice in routing.model?.noticePosted(notice) },
            onWithdraw: { [routing] id in routing.model?.noticeWithdrawn(id: id) },
            onOpenWindow: { [routing] in routing.openWindow() }))
        let automationsFile = AutomationsFile(url: paths.automationsFile)
        let runner = AutomationRunner(logsDirectory: paths.logsDirectory.appending(path: "automations"),
                                      ledgerFile: paths.logsDirectory.appending(path: "automations-ledger.json"))
        let dispatcher = AutomationDispatcher(file: automationsFile, runner: runner, notifier: notifier)

        // 7. The queue. One gate for the queue and every runner / lazy transcriber it is given (§13).
        let gate = BatchGate()
        let stages = StageBuilder(paths: paths, catalog: catalog, factory: factory, gate: gate)
        let automations = AutomationsStage(dispatcher: dispatcher, vault: { await output.vault() })
        let queue = QueueHolder(QueueAssembly.make(paths: paths, stages: await stages.standard(for: s),
                                                   automations: automations,
                                                   activity: RecordingSessionActivity(session: session), gate: gate))

        // 8. Devices and the coordinator.
        let registry = DeviceRegistry(storage: CurrentDevicesStorage(output: output, paths: paths),
                                      mac: SystemMacIdentityProvider())
        let monitor = DeviceMonitor(hardware: CoreAudioHardware(), power: WorkspaceSleepWakeObserver(),
                                    timer: TaskTimerScheduler())
        let coordinator = AutoRecordCoordinator(
            monitor: monitor, registry: registry, recorder: RecordingSessionControl(session: session), notifier: notifier,
            timer: TaskTimerScheduler(),
            config: { AutoRecordCoordinator.config(from: (try? await settings.load()) ?? AutoNoteCore.Settings()) })

        // 9. Cross-plan wiring. A queue-input change re-registers the stages on the same queue (ruling X19).
        let trigger = RecordingAutomationTrigger(dispatcher: dispatcher, manifests: manifests)
        let wiring = AppWiring(
            events: { await session.events() }, enqueuer: QueueEnqueuer(queue), notifier: notifier,
            listeners: [
                { await live.handle($0) },
                { await trigger.handle($0) },
                { e in for n in NoticeRelay.notices(for: e) { await notifier.post(n) } },
            ],
            onQueueInputsChanged: { new in
                await Self.rebuildQueue(new, output: output, stages: stages, queue: queue, registry: registry)
            })

        // 10. Adapters, the model and the socket server.
        let crashRecovery = CrashRecovery(paths: paths, manifests: manifests)
        let importer = AudioImporter(paths: paths, manifests: manifests)
        let queuePort = QueueAdapter(holder: queue)
        let ports = AppPorts(
            recorder: CoordinatorRecorderPort(coordinator: coordinator, elapsed: { await session.elapsed() }),
            events: SessionEventsPort(session: session),
            queue: queuePort,
            meetings: MeetingsAdapter(paths: paths, manifests: manifests, settings: settings, output: output,
                                      importer: importer, crashRecovery: crashRecovery,
                                      route: { await wiring.route($0) },
                                      queueStatus: { await queuePort.status() }, timeZone: .current),
            automations: AutomationsAdapter(file: automationsFile, dispatcher: dispatcher, runner: runner,
                                            manifests: manifests, paths: paths, output: output),
            live: live,
            outputFolder: PortableOutputFolderPort(output: output),
            opener: WorkspaceOpener())
        let model = AppModel(ports: ports)
        model.withdrawNotice = { [notifier] id in await notifier.withdraw(id: id) }
        routing.model = model
        let server = SocketServer(socketURL: paths.socketFile, handler: CommandRouter(ports: ports))

        // Plan 05 retention (R9).
        let retention = Retention(paths: paths, services: .standard)
        let retentionScheduler = RetentionScheduler(retention: retention, settings: settings)

        return AppEnvironment(
            environment: environment, paths: paths, settings: settings, manifests: manifests, output: output,
            session: session, coordinator: coordinator, registry: registry, monitor: monitor, queue: queue,
            wiring: wiring, live: live, crashRecovery: crashRecovery, catalog: catalog, models: models,
            automationsFile: automationsFile, retention: retention, retentionScheduler: retentionScheduler,
            ports: ports, model: model, notifier: notifier, server: server, routing: routing)
    }

    /// What a save did beyond writing `settings.json`, for the settings screen to show.
    struct SaveResult {
        /// `RegisterEventHotKey` status per readable shortcut (`eventHotKeyExistsErr` when another app holds it).
        var hotKeys: [ShortcutAction: OSStatus]
        var loginItem: LoginItem.Outcome
    }

    /// 11. Called by the settings screen after a save.
    @discardableResult
    func settingsSaved(old: AutoNoteCore.Settings, new: AutoNoteCore.Settings) async -> SaveResult {
        await wiring.settingsChanged(from: old, to: new)
        // The window's 「出力フォルダが未設定です」 banner and the menu's status line read `model.outputFolderAvailable`,
        // which otherwise waits for the 30-second periodic refresh: both testers of the 2026-10-27 UI audit saved a
        // folder and saw the warning stay. Re-read it now so the save is visibly effective.
        await model.refresh()
        let hotKeys = shortcutsChanged(new.shortcuts)
        let loginItem = reconcileLoginItem(launchAtLogin: new.launchAtLogin)
        return SaveResult(hotKeys: hotKeys, loginItem: loginItem)
    }

    /// Launch item 6 and the settings save: bring the login item in line with the setting, except under an
    /// overridden data directory, where `SMAppService` is never touched (ruling X22).
    @discardableResult
    func reconcileLoginItem(launchAtLogin: Bool) -> LoginItem.Outcome {
        guard !isDataDirectoryOverridden else {
            logger.info("login item: data directory overridden, left alone")
            return .leftAlone
        }
        return LoginItem.reconcile(launchAtLogin: launchAtLogin)
    }

    // MARK: - Notice loops (launch item 2)

    /// Each queue change: refresh the rows first, then turn the change into notices (overview §8b). The first status
    /// only seeds `previous`; a notice is posted once per meeting, generation and kind (rulings X16 / X43).
    func relayQueueNotices() async {
        var previous: QueueStatus?
        var posted = Set<String>()
        for await current in await ports.queue.updates() {
            guard let before = previous else {
                previous = current
                continue
            }
            previous = current
            await model.refresh()
            for notice in NoticeRelay.notices(previous: before, current: current, rows: model.meetings) {
                let key = Self.dedupeKey(notice, previous: before, current: current)
                guard posted.insert(key).inserted else { continue }
                await notifier.post(notice)
            }
        }
    }

    /// `model.outputFolderAvailable` going from available to missing posts `.outputFolderMissing`.
    func relayOutputFolderNotices() async {
        var wasAvailable: Bool?
        for await available in Observations({ [model] in model.outputFolderAvailable }) {
            defer { wasAvailable = available }
            guard let wasAvailable else { continue }
            for notice in NoticeRelay.notices(outputFolderWasAvailable: wasAvailable, isAvailable: available) {
                await notifier.post(notice)
            }
        }
    }

    /// `UserNotice.id` plus the job generation it belongs to, so a regenerated meeting can notify again.
    private static func dedupeKey(_ notice: UserNotice, previous: QueueStatus, current: QueueStatus) -> String {
        let meeting: MeetingID? = switch notice {
        case .minutesGenerated(let id, _), .transcriptOnly(let id), .claudeNotLoggedIn(let id), .overwriteConfirmation(let id):
            id
        default:
            nil
        }
        guard let meeting else { return notice.id }
        let item = current.items.first { $0.meetingID == meeting.rawValue }
            ?? previous.items.first { $0.meetingID == meeting.rawValue }
        return "\(notice.id):\(item?.generation ?? 0)"
    }

    // MARK: - Helpers

    /// The dictionary in the output folder (or its mirror); the default one when missing or unreadable.
    nonisolated private static func dictionary(_ output: OutputFolderServices) async -> DictionaryFile {
        do {
            guard let data = try await output.portable().read(.dictionary) else { return .default }
            return DictionaryFile.parse(String(decoding: data, as: UTF8.self)).dictionary
        } catch {
            logger.error("dictionary unreadable, using the default (\(String(describing: type(of: error)), privacy: .public))")
            return .default
        }
    }

    /// §8b (4): switch the output folder, re-register the standard stages with a new runner on the SAME queue and
    /// gate (jobs live in files, so nothing is lost), then reload the device list from the new folder.
    nonisolated private static func rebuildQueue(_ s: AutoNoteCore.Settings, output: OutputFolderServices, stages: StageBuilder,
                                                 queue: QueueHolder, registry: DeviceRegistry) async {
        do {
            try await output.rebuild(outputFolder: s.outputFolder)
        } catch {
            logger.error("output folder rebuild failed (\(String(describing: type(of: error)), privacy: .public))")
        }
        let q = await queue.queue
        for stage in await stages.standard(for: s) { await q.register(stage) }
        await registry.reload()
        logger.info("queue inputs changed: stages re-registered")
    }
}

// MARK: - Notice routing

/// Late binding from the notifier (built before the model) to the model.
@MainActor
private final class NoticeRouting {
    weak var model: AppModel?
    var openWindow: @MainActor () -> Void = { logger.info("open window requested (no window yet)") }

    func handle(_ action: UserNoticeAction) {
        // `SystemUserNotifier` already opened the privacy pane (ruling X43).
        guard action != .openPrivacySettings, let model else { return }
        Task { await model.perform(.notice(action)) }
        // A tap on a meeting's notice selects it (above) and shows the window.
        if case .openMeeting = action { openWindow() }
    }
}

// MARK: - Queue stages

/// Builds plan 05's standard stages for the given settings. Every runner and lazy transcriber shares `gate`.
private struct StageBuilder: Sendable {
    let paths: AppPaths
    let catalog: EngineCatalog
    let factory: TranscriberFactory
    let gate: BatchGate

    func standard(for s: AutoNoteCore.Settings) async -> [any QueueStage] {
        let override = EngineChoice.fromSettings(kind: s.finalEngine, model: s.finalModel, role: .batch,
                                                 machine: catalog.machine)
        let choice = await catalog.resolve(role: .batch, language: s.defaultLanguage, override: override)
            ?? EngineCatalog.defaults(for: catalog.machine).batch
        let transcriber = LazyBatchTranscriber(factory: factory, choice: choice, gate: gate)
        let runner = FinalTranscriptionRunner(transcriber: transcriber, engineName: choice.displayName, paths: paths,
                                              gate: gate)
        return PostProcessingPipeline.standardStages(runner: runner)
    }
}

/// Makes the batch transcriber on the first `transcribe`, so a missing model fails that job, not the launch.
private actor LazyBatchTranscriber: BatchTranscriber {
    private let factory: TranscriberFactory
    private let choice: EngineChoice
    private let gate: BatchGate
    private var made: (any BatchTranscriber)?

    init(factory: TranscriberFactory, choice: EngineChoice, gate: BatchGate) {
        self.factory = factory
        self.choice = choice
        self.gate = gate
    }

    func transcribe(file: URL, language: Language, hints: [String],
                    progress: @Sendable @escaping (Double) -> Void) async throws -> [Utterance] {
        let transcriber: any BatchTranscriber
        if let made {
            transcriber = made
        } else {
            transcriber = try await factory.makeBatch(choice, gate: gate)
            made = transcriber
        }
        return try await transcriber.transcribe(file: file, language: language, hints: hints, progress: progress)
    }
}

// MARK: - Device storage

/// `devices.json` of whichever output folder is current, so the registry survives an output-folder change. One
/// `PortableDevicesStorage` per config store, i.e. per output folder (ruling X26).
private actor CurrentDevicesStorage: DeviceRegistryStorage {
    private let output: OutputFolderServices
    private let paths: AppPaths
    private var cached: (store: ObjectIdentifier, storage: PortableDevicesStorage)?

    init(output: OutputFolderServices, paths: AppPaths) {
        self.output = output
        self.paths = paths
    }

    func load() async throws -> Data? { try await current().load() }
    func save(_ data: Data) async throws { try await current().save(data) }
    func backupCorrupt(_ data: Data) async throws { try await current().backupCorrupt(data) }

    /// Keyed on the store instance from one `portable()` read, so a `rebuild` cannot pair a new store with an old
    /// key. `SharedVaultServices` hands out one store per output folder, so this is one storage per folder.
    private func current() async -> PortableDevicesStorage {
        let store = await output.portable()
        let key = ObjectIdentifier(store)
        if let cached, cached.store == key { return cached.storage }
        let storage = PortableDevicesStorage(store: store, paths: paths)
        cached = (key, storage)
        return storage
    }
}
