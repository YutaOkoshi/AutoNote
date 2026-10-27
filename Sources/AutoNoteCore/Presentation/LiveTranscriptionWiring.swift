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
        let forwardTask = Task {
            for await utterances in list { self.publish(utterances) }
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
    }

    private func publish(_ utterances: [Utterance]) {
        latest = utterances
        for continuation in subscribers.values { continuation.yield(utterances) }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }
}
