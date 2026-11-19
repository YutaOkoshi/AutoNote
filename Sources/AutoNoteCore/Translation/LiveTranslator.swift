import Foundation
import os

private let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "LiveTranslator")

/// Which pending confirmed lines the live translation still does (spec 7): when more than `limit` wait, the older
/// ones are skipped (they keep only the original until the final translation) so it catches up with the newest.
public enum LiveTranslationBacklog {
    public static let limit = 2

    /// `pending` in order; returns (to translate, to skip), both in order.
    public static func select<T>(_ pending: [T], limit: Int = Self.limit) -> (translate: [T], skip: [T]) {
        guard pending.count > limit else { return (pending, []) }
        return (Array(pending.suffix(limit)), Array(pending.prefix(pending.count - limit)))
    }
}

/// The newest confirmed list of one meeting, handed from the feed reader to the translating loop, and the newest
/// live summary. The reader never waits for the loop (the feed itself keeps only the newest list), so a slow
/// translation never holds back the live transcript; a newer summary replaces one not taken yet.
actor LatestConfirmed {
    private var latest: [Utterance]?
    private var version = 0
    private var taken = 0
    private var summary: LiveSummaryState?
    private var summaryVersion = 0
    private var summaryTaken = 0
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?

    func set(_ list: [Utterance]) {
        latest = list
        version += 1
        wake()
    }

    func setSummary(_ state: LiveSummaryState) {
        summary = state
        summaryVersion += 1
        wake()
    }

    /// The newest summary once it is newer than the last one taken.
    func takeSummary() -> LiveSummaryState? {
        guard summaryVersion > summaryTaken else { return nil }
        summaryTaken = summaryVersion
        return summary
    }

    func finish() {
        finished = true
        wake()
    }

    /// Whether a newer list or summary (or the end) arrived since they were last taken.
    var hasNewer: Bool { finished || version > taken || summaryVersion > summaryTaken }

    /// The newest list once it or the summary is newer than the last one taken (empty before the first list);
    /// nil once finished.
    func next() async -> [Utterance]? {
        while !finished && version == taken && summaryVersion == summaryTaken {
            await withCheckedContinuation { waiter = $0 }
        }
        guard !finished else { return nil }
        taken = version
        return latest ?? []
    }

    private func wake() {
        waiter?.resume()
        waiter = nil
    }
}

/// The translation while recording (spec 7): only confirmed lines, in order, at a lower priority than the
/// recording and the live transcription, skipping ahead when behind. The model is loaded when the meeting's feed
/// starts and unloaded when it ends (the recording stopped). Any failure only ends the live translation.
public actor LiveTranslator {
    private let deps: TranslationDependencies
    private let broadcaster: TranslationBroadcaster
    private var sessions: [MeetingID: Task<Void, Never>] = [:]
    /// Each running session's box, so the live summaries reach it.
    private var boxes: [MeetingID: LatestConfirmed] = [:]
    /// The newest live summary per meeting (one may come before the session starts).
    private var summaries: [MeetingID: LiveSummaryState] = [:]

    public init(_ deps: TranslationDependencies, broadcaster: TranslationBroadcaster) {
        self.deps = deps
        self.broadcaster = broadcaster
    }

    /// One session per meeting feed, until `feeds` ends or the calling task is cancelled.
    public func run(feeds: AsyncStream<LiveConfirmedFeed>) async {
        await withTaskCancellationHandler {
            for await feed in feeds {
                guard sessions[feed.meetingID] == nil else { continue }
                let id = feed.meetingID
                sessions[id] = Task(priority: .utility) { [weak self] in
                    await self?.session(feed)
                    await self?.ended(id)
                }
            }
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }

    /// Follows the live summaries (`LiveSummaryScheduler.updates()`) until the stream ends: each new state goes to its
    /// meeting's session, which translates its changed texts once no confirmed line waits (spec 2026-11-19 録音中).
    public func follow(summaries updates: AsyncStream<LiveSummaryUpdate>) async {
        for await u in updates {
            guard let state = u.state, summaries[u.meetingID] != state else { continue }
            summaries[u.meetingID] = state
            await boxes[u.meetingID]?.setSummary(state)
        }
    }

    private func register(_ box: LatestConfirmed, for id: MeetingID) async {
        boxes[id] = box
        if let state = summaries[id] { await box.setSummary(state) }
    }

    private func unregister(_ id: MeetingID) { boxes[id] = nil }

    /// Waits for every running session (tests).
    func waitForSessions() async {
        for task in Array(sessions.values) { await task.value }
    }

    private func ended(_ id: MeetingID) { sessions[id] = nil }

    private func cancelAll() {
        for task in sessions.values { task.cancel() }
    }

    private func session(_ feed: LiveConfirmedFeed) async {
        let id = feed.meetingID
        let s = await deps.settings()
        guard TranslationModelPolicy.effectiveMode(s.translationMode, profile: deps.profile) == .duringRecording else {
            return
        }
        let model: TranslationModel, url: URL
        switch await deps.resolve(s) {
        case .success(let resolved): (model, url) = resolved
        case .failure(let e):
            logger.notice("\(id.rawValue, privacy: .public): no live translation (\(e.message, privacy: .public))")
            return
        }
        let box = LatestConfirmed()
        await register(box, for: id)
        // The reader only stores the newest list; it ends the box when the recording's feed ends.
        let reader = Task {
            for await list in feed.utterances { await box.set(list) }
            await box.finish()
        }
        defer {
            reader.cancel()
            unregister(id)
        }
        let target = s.translationTarget
        let store = deps.store
        let broadcaster = broadcaster
        let existing = store.loadLive(id)
        let existingSummary = store.loadSummary(id, .live)
        let now = deps.now
        do {
            try await deps.runtime.withModel(url) { translator in
                var document = existing ?? LiveTranslationDocument(model: model.name, target: target, lines: [])
                var attempted = Set(document.lines.map(\.key))
                var history: [TranslationPair] = []
                var summaryDocument = existingSummary
                    ?? SummaryTranslationDocument(model: model.name, modelRevision: model.revision, target: target,
                                                  updatedAt: now())
                /// The newest summary whose texts are not all translated yet.
                var summary: LiveSummaryState?
                while let list = await box.next() {
                    if let newer = await box.takeSummary() { summary = newer }
                    var interrupted = false
                    while !Task.isCancelled {
                        let pending = list.filter { u in
                            u.isFinal && !LiveFeed.isMarker(u) && !attempted.contains(TranslationKey.live(u))
                        }
                        let choice = LiveTranslationBacklog.select(pending)
                        for u in choice.skip { attempted.insert(TranslationKey.live(u)) }
                        guard let u = choice.translate.first else { break }
                        let key = TranslationKey.live(u)
                        attempted.insert(key)
                        guard let d = TranslationLanguageDetector.direction(of: u.text, target: target) else { continue }
                        let text = try await translator.translate(u.text, from: d.source, to: d.target, history: history)
                        guard !text.isEmpty else { continue }
                        history = Array((history + [TranslationPair(source: u.text, sourceLanguage: d.source,
                                                                    translation: text, targetLanguage: d.target)])
                            .suffix(PlamoPrompt.historyLimit))
                        let line = LiveTranslatedLine(key: key, sourceLanguage: d.source, targetLanguage: d.target, text: text)
                        document.lines.append(line)
                        try? store.saveLive(document, for: id)
                        broadcaster.send(.live(id, line))
                        // A newer list holds these lines too: take it, so the backlog is measured against the newest.
                        if await box.hasNewer {
                            interrupted = true
                            break
                        }
                    }
                    if Task.isCancelled { break }
                    if interrupted { continue }
                    // No confirmed line waits: the summary's changed texts, until something newer arrives (a newer
                    // summary replaces this one; a new line goes first).
                    guard let current = summary else { continue }
                    let texts = SummaryTranslation.liveTexts(current)
                    guard let to = SummaryTranslation.targetLanguage(for: texts, setting: target) else {
                        summary = nil
                        continue
                    }
                    summaryDocument.keepOnly(texts)
                    var finished = true
                    for item in SummaryTranslation.pending(texts, target: to, document: summaryDocument) {
                        if await box.hasNewer {
                            finished = false
                            break
                        }
                        let text = try await translator.translateSummary(item.text, from: item.source, to: item.target)
                        summaryDocument.entries.append(SummaryTranslatedText(
                            sourceHash: TranslationKey.textHash(item.text), sourceLanguage: item.source,
                            targetLanguage: item.target, text: text))
                        summaryDocument.model = model.name
                        summaryDocument.modelRevision = model.revision
                        summaryDocument.target = target
                        summaryDocument.updatedAt = now()
                        try? store.saveSummary(summaryDocument, .live, for: id)
                        broadcaster.send(.liveSummary(id, summaryDocument))
                    }
                    if finished { summary = nil }
                }
            }
        } catch is CancellationError {
            logger.notice("\(id.rawValue, privacy: .public): live translation cancelled")
        } catch {
            logger.error("\(id.rawValue, privacy: .public): live translation stopped (\(String(describing: error), privacy: .public))")
        }
    }
}
