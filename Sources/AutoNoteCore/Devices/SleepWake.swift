import AppKit

public enum PowerEvent: Sendable {
    case willSleep, didWake
}

public protocol SleepWakeObserving: Sendable {
    func events() -> AsyncStream<PowerEvent>
}

/// System sleep/wake from `NSWorkspace.shared.notificationCenter`, merged into one stream.
public struct WorkspaceSleepWakeObserver: SleepWakeObserving {
    public init() {}

    public func events() -> AsyncStream<PowerEvent> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            let sleep = Task {
                for await _ in center.notifications(named: NSWorkspace.willSleepNotification).map({ _ in () }) {
                    continuation.yield(.willSleep)
                }
            }
            let wake = Task {
                for await _ in center.notifications(named: NSWorkspace.didWakeNotification).map({ _ in () }) {
                    continuation.yield(.didWake)
                }
            }
            continuation.onTermination = { _ in sleep.cancel(); wake.cancel() }
        }
    }
}
