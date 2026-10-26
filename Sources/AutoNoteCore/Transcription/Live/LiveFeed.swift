import Foundation

/// Merges the mic and system live transcribers into one display list and keeps `live.json`
/// (confirmed utterances only, before replacement) up to date.
public actor LiveFeed {
    public static let pauseMarkerText = "── 一時停止 ──"

    public static func bookmarkMarkerText(_ note: String?) -> String {
        guard let note, !note.isEmpty else { return "── ブックマーク ──" }
        return "── ブックマーク: \(note) ──"
    }

    /// Markers are `.unknown`, final, and carry one of the marker texts.
    public static func isMarker(_ u: Utterance) -> Bool {
        guard u.speaker == .unknown, u.isFinal else { return false }
        return u.text == pauseMarkerText || u.text == "── ブックマーク ──"
            || (u.text.hasPrefix("── ブックマーク: ") && u.text.hasSuffix(" ──"))
    }

    /// Builds the feed the settings ask for, falling back as `EngineCatalog.resolve` does.
    public static func make(settings: Settings, catalog: EngineCatalog, factory: TranscriberFactory,
                            dictionary: DictionaryFile, liveJSON: URL) async throws -> LiveFeed {
        let override = EngineChoice.fromSettings(kind: settings.liveEngine, model: settings.liveModel,
                                                 role: .live, machine: catalog.machine)
        guard let choice = await catalog.resolve(role: .live, language: settings.defaultLanguage, override: override) else {
            throw TranscriptionError.engineUnavailable("no live engine is available for \(settings.defaultLanguage.rawValue)")
        }
        let mic = try await factory.makeLive(choice)
        let system = try await factory.makeLive(choice)
        return LiveFeed(transcribers: [.mic: mic, .system: system], replacer: Replacer(dictionary.replacements),
                        liveJSON: liveJSON, engineName: choice.displayName)
    }

    private struct Key: Hashable {
        var speaker: Speaker
        var start: TimelineTime
    }

    public nonisolated let engineName: String
    private let transcribers: [Track: any LiveTranscriber]
    private let replacer: Replacer
    private let liveJSON: URL
    private let saveInterval: Duration
    private let clock = ContinuousClock()

    public private(set) var failures: [Track: String] = [:]
    private var utterances: [Key: Utterance] = [:]
    private var markers: [Utterance] = []
    private var language: Language = .ja
    private var lastSave: ContinuousClock.Instant?
    private var finishing = false
    private var subscriptions: [Task<Void, Never>] = []
    private var continuation: AsyncStream<[Utterance]>.Continuation?

    public init(transcribers: [Track: any LiveTranscriber], replacer: Replacer, liveJSON: URL,
                engineName: String, saveInterval: Duration = .seconds(5)) {
        self.transcribers = transcribers
        self.replacer = replacer
        self.liveJSON = liveJSON
        self.engineName = engineName
        self.saveInterval = saveInterval
    }

    /// Starts every track; a track that fails is recorded in `failures`. Throws only when none starts.
    /// Each stream element is the whole display list (only the newest is kept for a slow reader).
    public func start(language: Language, hints: [String]) async throws -> AsyncStream<[Utterance]> {
        self.language = language
        let (stream, continuation) = AsyncStream<[Utterance]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        var started = 0
        for track in [Track.mic, .system] {
            guard let transcriber = transcribers[track] else { continue }
            do {
                let results = try await transcriber.start(language: language, hints: hints)
                started += 1
                subscriptions.append(Task {
                    for await u in results { self.receive(u, from: track) }
                    self.streamEnded(track)
                })
            } catch {
                failures[track] = String(describing: error)
            }
        }
        guard started > 0 else {
            continuation.finish()
            self.continuation = nil
            let detail = [Track.mic, .system].compactMap { t in failures[t].map { "\(t.rawValue): \($0)" } }
            throw TranscriptionError.engineUnavailable(detail.joined(separator: "; "))
        }
        return stream
    }

    public func feed(_ chunk: AudioChunk) async {
        guard failures[chunk.track] == nil, let transcriber = transcribers[chunk.track] else { return }
        await transcriber.feed(chunk)
    }

    public func pause(at time: TimelineTime) {
        addMarker(Self.pauseMarkerText, at: time)
    }

    /// Nothing is shown on resume; the pause interval itself is kept in the manifest.
    public func resume(at time: TimelineTime) {}

    public func bookmark(_ b: Bookmark) {
        addMarker(Self.bookmarkMarkerText(b.note), at: b.at)
    }

    /// Finals, partials and markers by start (mic before system at the same time), text replaced.
    public func snapshot() -> [Utterance] {
        let replaced = utterances.values.map { u in
            var u = u
            u.text = replacer.apply(u.text)
            return u
        }
        return Self.ordered(replaced + markers)
    }

    /// Finishes both transcribers, drains their results, writes `live.json` and ends the stream.
    public func finish() async throws -> Transcript {
        finishing = true
        for track in [Track.mic, .system] where failures[track] == nil {
            await transcribers[track]?.finish()
        }
        for task in subscriptions { await task.value }
        subscriptions = []
        defer {
            continuation?.finish()
            continuation = nil
        }
        let transcript = confirmedTranscript()
        try write(transcript)
        return transcript
    }

    private func receive(_ raw: Utterance, from track: Track) {
        var u = raw
        u.speaker = track == .mic ? .me : .other
        let key = Key(speaker: u.speaker, start: u.start)
        if u.isFinal && u.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            utterances[key] = nil
        } else {
            utterances[key] = u
        }
        publish()
        if u.isFinal { saveIfDue() }
    }

    /// A stream that ends before `finish()` means the track died mid-meeting (its transcriber gave up).
    private func streamEnded(_ track: Track) {
        guard !finishing, failures[track] == nil else { return }
        failures[track] = "live stream ended unexpectedly"
        publish()
    }

    private func addMarker(_ text: String, at time: TimelineTime) {
        markers.append(Utterance(start: time, end: nil, speaker: .unknown, text: text, isFinal: true))
        publish()
    }

    private func publish() {
        continuation?.yield(snapshot())
    }

    private func saveIfDue() {
        let now = clock.now
        if let lastSave, now - lastSave < saveInterval { return }
        // A failed periodic save is retried on the next final and surfaced by `finish()`.
        try? write(confirmedTranscript())
    }

    private func confirmedTranscript() -> Transcript {
        Transcript(utterances: Self.ordered(utterances.values.filter(\.isFinal)), engine: engineName, language: language)
    }

    private func write(_ transcript: Transcript) throws {
        try FileManager.default.createDirectory(at: liveJSON.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AutoNoteJSON.encoder().encode(transcript).write(to: liveJSON, options: .atomic)
        lastSave = clock.now
    }

    private static func rank(_ s: Speaker) -> Int {
        switch s {
        case .me: 0
        case .other: 1
        case .unknown: 2
        }
    }

    /// Stable: markers at the same time keep their insertion order.
    private static func ordered(_ list: [Utterance]) -> [Utterance] {
        list.enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            let ra = rank(a.element.speaker), rb = rank(b.element.speaker)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }
}
