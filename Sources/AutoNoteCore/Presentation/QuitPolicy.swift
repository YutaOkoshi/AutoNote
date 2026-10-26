import Foundation

public enum QuitReason: Sendable { case user, powerOff }

public enum QuitDecision: Equatable, Sendable { case terminateNow, cancelCountdownThenTerminate, confirm, stopThenTerminate }

/// What quitting does in each recorder state: a user quit asks first while recording; a power-off stops and saves.
public enum QuitPolicy {
    public static let confirmMessage = "録音中です。停止して終了しますか？"

    public static func decide(_ s: RecorderState, reason: QuitReason) -> QuitDecision {
        switch s {
        case .idle: .terminateNow
        case .countdown: .cancelCountdownThenTerminate
        case .recording, .paused, .grace: reason == .user ? .confirm : .stopThenTerminate
        }
    }
}
