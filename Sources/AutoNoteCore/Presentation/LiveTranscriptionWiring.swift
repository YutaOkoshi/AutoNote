import Foundation
import os

private let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "LiveTranscriptionWiring")

/// What `LiveTranscriptionWiring` needs to start one meeting's live transcript.
public struct LiveFeedStart: Sendable {
    public var feed: LiveFeed
    public var language: Language
    public var hints: [String]

    public init(feed: LiveFeed, language: Language, hints: [String]) {
        self.feed = feed
        self.language = language
        self.hints = hints
    }
}

/// One meeting's confirmed utterances: each element is the whole display list reduced to finals without markers
/// (dictionary replacements applied). Only the newest is kept for a slow reader; the stream ends after the meeting's
/// `LiveFeed.finish()` has drained its last results.
public struct LiveConfirmedFeed: Sendable {
    public let meetingID: MeetingID
    public let utterances: AsyncStream<[Utterance]>

    public init(meetingID: MeetingID, utterances: AsyncStream<[Utterance]>) {
        self.meetingID = meetingID
        self.utterances = utterances
    }
}

/// Drives a `LiveFeed` from the recording events (overview §8b (3)) and republishes its display list.
/// A feed that cannot be made or started is logged; the meeting records on without a live transcript.
public actor LiveTranscriptionWiring: LiveTranscriptPort {
    private struct Running {
        var id: MeetingID
        var feed: LiveFeed
        var audioTasks: [Task<Void, Never>]
        var forwardTask: Task<Void, Never>
    }

    private let audio: @Sendable (Track) async -> AsyncStream<AudioChunk>
    private let makeFeed: @Sendable (MeetingID) async throws -> LiveFeedStart
    private var running: Running?
    private var subscribers: [UUID: AsyncStream<[Utterance]>.Continuation] = [:]
    /// The newest display list, handed to each new subscriber; nil until a feed has published one.
    private(set) var latest: [Utterance]?
    private var feedSubscribers: [UUID: AsyncStream<LiveConfirmedFeed>.Continuation] = [:]
    /// Kept outside `Running`: `stop()` clears `running` first, but the forward task still publishes until it ends.
    private var confirmedStreams: [MeetingID: [UUID: AsyncStream<[Utterance]>.Continuation]] = [:]
    private var latestConfirmed: [MeetingID: [Utterance]] = [:]

    public init(audio: @Sendable @escaping (Track) async -> AsyncStream<AudioChunk>,
                makeFeed: @Sendable @escaping (MeetingID) async throws -> LiveFeedStart) {
        self.audio = audio
        self.makeFeed = makeFeed
    }

    /// Must be called serially, one event at a time (AppWiring's per-listener FIFO inbox does this).
    public func handle(_ e: RecordingEvent) async {
        switch e {
        case .started(let id):
            await stop()
            await begin(id)
        case .paused(let t):
            await running?.feed.pause(at: t)
        case .resumed(let t):
            await running?.feed.resume(at: t)
        case .bookmarked(let b):
            await running?.feed.bookmark(b)
        case .stopped:
            await stop()
        default:
            break
        }
    }

    /// Each subscriber gets the latest display list first (when there is one), then every new one.
    public func updates() -> AsyncStream<[Utterance]> {
        let (stream, continuation) = AsyncStream<[Utterance]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        subscribers[id] = continuation
        if let latest { continuation.yield(latest) }
        return stream
    }

    /// Each subscriber gets one `LiveConfirmedFeed` per meeting whose feed started (the running one at once).
    public func confirmedFeeds() -> AsyncStream<LiveConfirmedFeed> {
        let (stream, continuation) = AsyncStream<LiveConfirmedFeed>.makeStream()
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribeFeeds(id) }
        }
        feedSubscribers[id] = continuation
        if let running { continuation.yield(confirmedFeed(for: running.id)) }
        return stream
    }

    private func confirmedFeed(for meeting: MeetingID) -> LiveConfirmedFeed {
        let (stream, continuation) = AsyncStream<[Utterance]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribeConfirmed(id, from: meeting) }
        }
        confirmedStreams[meeting, default: [:]][id] = continuation
        if let latest = latestConfirmed[meeting] { continuation.yield(latest) }
        return LiveConfirmedFeed(meetingID: meeting, utterances: stream)
    }

    private func begin(_ id: MeetingID) async {
        // Clear the previous meeting first: a meeting whose feed cannot be built shows no live transcript.
        publish([])
        let start: LiveFeedStart
        let list: AsyncStream<[Utterance]>
        do {
            start = try await makeFeed(id)
            list = try await start.feed.start(language: start.language, hints: start.hints)
        } catch {
            logger.error("\(id.rawValue, privacy: .public): live transcript unavailable (\(String(describing: error), privacy: .public))")
            return
        }
        let feed = start.feed
        // Register before the forward task can publish, so no subscriber misses the first list.
        for continuation in feedSubscribers.values { continuation.yield(confirmedFeed(for: id)) }
        let forwardTask = Task {
            for await utterances in list { self.publish(utterances, for: id) }
        }
        var audioTasks: [Task<Void, Never>] = []
        for track in [Track.mic, .system] {
            let chunks = await audio(track)
            audioTasks.append(Task {
                for await chunk in chunks {
                    if Task.isCancelled { break }
                    await feed.feed(chunk)
                }
            })
        }
        running = Running(id: id, feed: feed, audioTasks: audioTasks, forwardTask: forwardTask)
    }

    /// Stops feeding audio, then finishes the feed (which writes `live.json`). A finish error is logged only.
    private func stop() async {
        guard let current = running else { return }
        running = nil
        for task in current.audioTasks { task.cancel() }
        for task in current.audioTasks { await task.value }
        do {
            _ = try await current.feed.finish()
        } catch {
            logger.error("\(current.id.rawValue, privacy: .public): live transcript finish failed (\(String(describing: error), privacy: .public))")
        }
        await current.forwardTask.value
        // The forward task has published the drained list; ending the confirmed streams lets the reader run its last pass.
        for continuation in (confirmedStreams.removeValue(forKey: current.id) ?? [:]).values { continuation.finish() }
        latestConfirmed[current.id] = nil
    }

    private func publish(_ utterances: [Utterance]) {
        latest = utterances
        for continuation in subscribers.values { continuation.yield(utterances) }
    }

    /// Display subscribers get every list; the meeting's confirmed streams get its finals when they change.
    private func publish(_ utterances: [Utterance], for meeting: MeetingID) {
        publish(utterances)
        let confirmed = LiveSummaryInputBuilder.finalUtterances(utterances)
        guard latestConfirmed[meeting] != confirmed else { return }
        latestConfirmed[meeting] = confirmed
        for continuation in (confirmedStreams[meeting] ?? [:]).values { continuation.yield(confirmed) }
    }

    private func unsubscribeFeeds(_ id: UUID) {
        feedSubscribers[id] = nil
    }

    private func unsubscribeConfirmed(_ id: UUID, from meeting: MeetingID) {
        confirmedStreams[meeting]?[id] = nil
        if confirmedStreams[meeting]?.isEmpty == true { confirmedStreams[meeting] = nil }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }
}
