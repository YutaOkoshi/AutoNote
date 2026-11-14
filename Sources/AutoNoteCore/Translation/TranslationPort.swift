import Foundation
import Synchronization

/// Where a meeting's post-recording translation is.
public enum TranslationJobState: Equatable, Sendable {
    /// Waiting for the runtime (another translation holds it).
    case queued
    case running(TranslationProgress)
    /// Paused while a recording runs; it continues after the stop.
    case waitingForRecording(TranslationProgress)
    /// The run failed; the meeting itself is untouched (spec 6). 「再試行」 starts it again.
    case failed(String)
}

public enum TranslationUpdate: Equatable, Sendable {
    /// A meeting's job state; nil when no job runs for it any more (finished or cancelled). `revision` grows with
    /// every finished run, so a view re-reads `translation.json`.
    case job(MeetingID, TranslationJobState?, revision: Int)
    /// One more translated line of the recording meeting's live transcript.
    case live(MeetingID, LiveTranslatedLine)
}

/// What the meeting screen needs to offer 「翻訳する」 at all (spec 9: also when the mode is off).
public enum TranslationAvailability: Equatable, Sendable {
    case ready
    case runtimeUnavailable
    case licenseNotAccepted
    case modelNotInstalled(TranslationModel)

    public var isReady: Bool { self == .ready }
}

/// One meeting's translation as the transcript views show it.
public struct MeetingTranslation: Equatable, Sendable {
    public var status: TranslationStatus
    /// Translations of the final transcript by utterance index; only entries whose original text still matches,
    /// and none at all when the translation is stale.
    public var byIndex: [Int: TranslatedUtterance]
    /// The translations made while recording, by `TranslationKey.live`.
    public var live: [String: LiveTranslatedLine]
    /// Whether the meeting has a final transcript (what 「翻訳する」 translates).
    public var hasTranscript: Bool

    public init(status: TranslationStatus = .none, byIndex: [Int: TranslatedUtterance] = [:],
                live: [String: LiveTranslatedLine] = [:], hasTranscript: Bool = false) {
        self.status = status
        self.byIndex = byIndex
        self.live = live
        self.hasTranscript = hasTranscript
    }

    public static let empty = MeetingTranslation()

    /// The usable entries of `document` for `transcript` (nothing when stale).
    public static func make(document: TranslationDocument?, transcript: Transcript?,
                            live: LiveTranslationDocument?) -> MeetingTranslation {
        let status = TranslationStatus.of(document, transcript: transcript)
        var byIndex: [Int: TranslatedUtterance] = [:]
        if let document, let transcript, status != .stale {
            for e in document.entries where transcript.utterances.indices.contains(e.index)
                && TranslationKey.textHash(transcript.utterances[e.index].text) == e.sourceHash {
                byIndex[e.index] = e
            }
        }
        let lines = Dictionary((live?.lines ?? []).map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
        return MeetingTranslation(status: status, byIndex: byIndex, live: lines, hasTranscript: transcript != nil)
    }
}

/// The translation feature as the window and the menu see it. Implemented by `TranslationService`.
public protocol TranslationPort: Sendable {
    /// Every running job's state first, then every change.
    func updates() async -> AsyncStream<TranslationUpdate>
    func meetingTranslation(_ id: MeetingID) async -> MeetingTranslation
    /// 「翻訳する」 / 「訳し直す」 / 「再試行」: starts (or continues) the meeting's translation and returns at once.
    func translate(_ id: MeetingID) async throws
    func availability() async -> TranslationAvailability
    /// The 「訳文」 switch, kept app-wide in the settings.
    func setShown(_ shown: Bool) async
}

/// A build or a test without the feature: nothing ever translates.
public struct NoTranslationPort: TranslationPort {
    public init() {}
    public func updates() async -> AsyncStream<TranslationUpdate> { AsyncStream { _ in } }
    public func meetingTranslation(_ id: MeetingID) async -> MeetingTranslation { .empty }
    public func translate(_ id: MeetingID) async throws { throw AppCommandError.invalid(TranslationError.runtimeUnavailable.message) }
    public func availability() async -> TranslationAvailability { .runtimeUnavailable }
    public func setShown(_ shown: Bool) async {}
}

/// Fans translation updates out to every subscriber; the live and the post-recording side share one.
public final class TranslationBroadcaster: Sendable {
    private let subscribers = Mutex<[UUID: AsyncStream<TranslationUpdate>.Continuation]>([:])

    public init() {}

    /// `initial` is yielded first (the current job states).
    public func subscribe(initial: [TranslationUpdate] = []) -> AsyncStream<TranslationUpdate> {
        let (stream, continuation) = AsyncStream<TranslationUpdate>.makeStream()
        let id = UUID()
        for u in initial { continuation.yield(u) }
        subscribers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.subscribers.withLock { _ = $0.removeValue(forKey: id) } }
        return stream
    }

    public func send(_ update: TranslationUpdate) {
        let current = subscribers.withLock { Array($0.values) }
        for c in current { c.yield(update) }
    }
}
