import Foundation

public struct SilenceWarning: Equatable, Sendable {
    public var track: Track
    public var message: String

    public init(track: Track, message: String) {
        self.track = track
        self.message = message
    }
}

/// Decides when to tell the user that the microphone is silent or that system audio is not arriving.
/// Only recorded (non-paused) time counts. Each warning is returned once.
public struct SilenceMonitor: Sendable {
    public static let micWindowSeconds: Double = 15
    public static let systemWindowSeconds: Double = 60
    public static let nearSilencePeakDBFS: Double = -60
    public static let micMessage = "マイクが無音です。機材と許可を確認してください"
    public static let systemMessage = "システム音声が届いていません。システム音声の録音許可と、会議アプリの音が出ているかを確認してください"

    private var lastTick: TimelineTime
    private var micSeconds = 0.0
    private var systemSilentSeconds = 0.0
    private var micPeak = -Double.infinity
    private var micJudged = false
    private var systemWarned = false

    public init(start: TimelineTime) {
        self.lastTick = start
    }

    public mutating func observe(_ track: Track, chunk: AudioChunk) {
        switch track {
        case .mic:
            micPeak = max(micPeak, AudioLevel.peakDBFS(chunk.samples))
        case .system:
            if chunk.samples.contains(where: { $0 != 0 }) { systemSilentSeconds = 0 }
        }
    }

    public mutating func tick(now: TimelineTime, paused: Bool) -> [SilenceWarning] {
        let delta = max(0, now.seconds - lastTick.seconds)
        lastTick = now
        if !paused {
            micSeconds += delta
            systemSilentSeconds += delta
        }
        var warnings: [SilenceWarning] = []
        if !micJudged, micSeconds >= Self.micWindowSeconds {
            micJudged = true
            if micPeak < Self.nearSilencePeakDBFS {
                warnings.append(SilenceWarning(track: .mic, message: Self.micMessage))
            }
        }
        if !systemWarned, systemSilentSeconds >= Self.systemWindowSeconds {
            systemWarned = true
            warnings.append(SilenceWarning(track: .system, message: Self.systemMessage))
        }
        return warnings
    }
}
