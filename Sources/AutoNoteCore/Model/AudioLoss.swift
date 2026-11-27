import Foundation

/// A track of a live recording that is missing part of its audio (`manifest.audio_loss`). Separate from
/// `silence_warning`, which only says a track sounded silent.
public struct TrackLoss: Codable, Equatable, Hashable, Sendable {
    public var track: Track
    /// Seconds judged missing (`AudioLossRule.lostSeconds`); 0 when only the failure is known.
    public var seconds: Int
    /// The track's source or writer reported a failure during the recording (`RecordingEvent.sourceFailed`).
    public var sourceFailed: Bool

    public init(track: Track, seconds: Int, sourceFailed: Bool) {
        self.track = track; self.seconds = seconds; self.sourceFailed = sourceFailed
    }
}

/// When a track counts as having lost audio. The only place these thresholds live.
public enum AudioLossRule {
    /// A track is lossy from this many missing seconds…
    public static let minimumLostSeconds = 30
    /// …or from this share of the recording, whichever is larger.
    public static let lostFraction = 0.10

    public static func threshold(recordedSeconds: Double) -> Int {
        max(minimumLostSeconds, Int((max(0, recordedSeconds) * lostFraction).rounded(.up)))
    }

    /// Seconds of the track that should have held audio and did not.
    /// - microphone: seconds without callbacks, outside the recording's pauses. An open input always calls back, so
    ///   none means the input was gone. All-zero seconds do not count: a headset's mute button delivers exact zeros.
    /// - system audio: seconds in which another process was playing audio and nothing but zeros (or no callback)
    ///   arrived. With nobody playing, an idle tap delivers zeros or no callbacks at all, and that is not a loss.
    public static func lostSeconds(_ health: TrackHealth) -> Int {
        switch health.track {
        case .mic: max(0, health.noCallbackSeconds - (health.pausedNoCallbackSeconds ?? 0))
        case .system: (health.suspectZeroSeconds ?? 0) + (health.suspectNoCallbackSeconds ?? 0)
        }
    }

    /// The lossy tracks (microphone first), or nil when there is none. `failedTracks`: tracks whose source or writer
    /// reported a failure; those are lossy whatever their seconds.
    public static func evaluate(health: [TrackHealth]?, failedTracks: Set<Track>, recordedSeconds: Double) -> [TrackLoss]? {
        let limit = threshold(recordedSeconds: recordedSeconds)
        let losses = [Track.mic, .system].compactMap { track -> TrackLoss? in
            let seconds = health?.first { $0.track == track }.map(lostSeconds) ?? 0
            let failed = failedTracks.contains(track)
            guard failed || seconds >= limit else { return nil }
            return TrackLoss(track: track, seconds: seconds, sourceFailed: failed)
        }
        return losses.isEmpty ? nil : losses
    }

    /// For a meeting combined from several recordings: per track, the sources' losses added up.
    public static func combine(_ sources: [[TrackLoss]?]) -> [TrackLoss]? {
        let all = sources.compactMap { $0 }.flatMap { $0 }
        let losses = [Track.mic, .system].compactMap { track -> TrackLoss? in
            let mine = all.filter { $0.track == track }
            guard !mine.isEmpty else { return nil }
            return TrackLoss(track: track, seconds: mine.reduce(0) { $0 + $1.seconds }, sourceFailed: mine.contains { $0.sourceFailed })
        }
        return losses.isEmpty ? nil : losses
    }
}

extension TrackHealth {
    /// For a meeting combined from several recordings: per track, the sources' counters added up. An optional counter
    /// stays nil only when no source has it.
    public static func combine(_ sources: [[TrackHealth]?]) -> [TrackHealth]? {
        let all = sources.compactMap { $0 }.flatMap { $0 }
        func sum(_ list: [TrackHealth], _ value: (TrackHealth) -> Int?) -> Int? {
            let values = list.compactMap(value)
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        let result = [Track.mic, .system].compactMap { track -> TrackHealth? in
            let mine = all.filter { $0.track == track }
            guard !mine.isEmpty else { return nil }
            return TrackHealth(track: track, noCallbackSeconds: mine.reduce(0) { $0 + $1.noCallbackSeconds },
                               zeroSeconds: mine.reduce(0) { $0 + $1.zeroSeconds },
                               restarts: mine.reduce(0) { $0 + $1.restarts }, callbacks: mine.reduce(0) { $0 + $1.callbacks },
                               droppedFrames: sum(mine, \.droppedFrames), suspectZeroSeconds: sum(mine, \.suspectZeroSeconds),
                               suspectNoCallbackSeconds: sum(mine, \.suspectNoCallbackSeconds),
                               pausedNoCallbackSeconds: sum(mine, \.pausedNoCallbackSeconds))
        }
        return result.isEmpty ? nil : result
    }
}
