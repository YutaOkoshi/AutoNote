import Foundation
import os

private let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "AppWiring")

/// Where a finished recording goes for post-processing (the queue in the app, a fake in tests).
public protocol MeetingEnqueuing: Sendable {
    func enqueue(_ id: MeetingID) async
}

/// Enqueues on whichever queue the holder has now.
public struct QueueEnqueuer: MeetingEnqueuing {
    private let holder: QueueHolder

    public init(_ holder: QueueHolder) { self.holder = holder }

    public func enqueue(_ id: MeetingID) async {
        await holder.queue.enqueue(id)
    }
}

/// Builds the post-processing queue with `automations` always last and the given `gate` (the same instance the
/// final-transcription runner waits on, so recording pauses it; spec §13, overview §8b (5)).
public enum QueueAssembly {
    public static func make(paths: AppPaths, stages: [any QueueStage], automations: AutomationsStage,
                            activity: any RecordingActivity, gate: BatchGate) -> PostProcessingQueue {
        PostProcessingQueue(paths: paths, stages: stages + [automations], activity: activity, gate: gate)
    }
}

/// The cross-plan wiring of overview §8b: one subscription to the recording events, fanned out to the listeners,
/// and the one entry point (`route`) for stopped, imported and recovered meetings.
public actor AppWiring {
    private let events: @Sendable () async -> AsyncStream<RecordingEvent>
    private let enqueuer: any MeetingEnqueuing
    private let notifier: any UserNotifier
    private let listeners: [@Sendable (RecordingEvent) async -> Void]
    private let onQueueInputsChanged: @Sendable (Settings) async -> Void

    public init(events: @Sendable @escaping () async -> AsyncStream<RecordingEvent>, enqueuer: any MeetingEnqueuing,
                notifier: any UserNotifier, listeners: [@Sendable (RecordingEvent) async -> Void] = [],
                onQueueInputsChanged: @Sendable @escaping (Settings) async -> Void = { _ in }) {
        self.events = events
        self.enqueuer = enqueuer
        self.notifier = notifier
        self.listeners = listeners
        self.onQueueInputsChanged = onQueueInputsChanged
    }

    /// Subscribes once and returns when the event stream ends (or the calling task is cancelled). Each listener
    /// has its own FIFO consumer, so a slow listener delays neither `route` nor the other listeners (ruling X7).
    public func run() async {
        let stream = await events()
        // Unbounded on purpose: recording events are few, and none may be dropped.
        let inboxes = listeners.map { _ in AsyncStream<RecordingEvent>.makeStream() }
        await withDiscardingTaskGroup { group in
            for (listener, inbox) in zip(listeners, inboxes) {
                group.addTask {
                    for await event in inbox.stream { await listener(event) }
                }
            }
            for await event in stream {
                for inbox in inboxes { inbox.continuation.yield(event) }
                if case .stopped(let manifest, _) = event { await route(manifest) }
            }
            for inbox in inboxes { inbox.continuation.finish() }
        }
    }

    /// The common exit of a stopped recording, a finished import and a recovered one (overview §8b (1)(2)).
    /// The manifest status decides, never the stop reason.
    public func route(_ manifest: Manifest) async {
        switch manifest.status {
        case .tooShort:
            await notifier.post(.recordingTooShort(manifest.id))
        case .recorded:
            await enqueuer.enqueue(manifest.id)
        default:
            logger.notice("route \(manifest.id.rawValue, privacy: .public): status \(manifest.status.rawValue, privacy: .public), nothing to do")
        }
    }

    /// Only the queue's inputs (output folder, final engine and model) rebuild it.
    public func settingsChanged(from old: Settings, to new: Settings) async {
        guard old.outputFolder != new.outputFolder || old.finalEngine != new.finalEngine
            || old.finalModel != new.finalModel else { return }
        await onQueueInputsChanged(new)
    }
}
