import Foundation

/// A call that does not return until the test lets it: what a fake uses to play a hardware call that hangs.
///
/// A fixed sleep ("blocks for 3 s") makes the test a race against the clock: on a stalled machine the sleep is over
/// before the code under test gave up waiting, and the test cannot tell. With a hold the order is the verdict: the
/// code under test returned while the call was still held (`expired == false`), then the test releases it.
/// A held call lets go by itself after `limit`, so a test that would otherwise hang ends with `expired == true`;
/// the hold is released with it, so the calls after that one go through and the test fails after one `limit`, not
/// one per call. `limit` is the test target's `testPatience` (which this target cannot see): keep the two equal,
/// or a hold gives up before the test stopped waiting for the code that should have returned.
public final class BlockingHold: @unchecked Sendable {
    private let condition = NSCondition()
    private let limit: TimeInterval
    private var held = false
    private var _expired = false
    private var _waiting = 0

    public init(limit: TimeInterval = 120) { self.limit = limit }

    /// From now on `wait()` blocks its caller.
    public func hold() { condition.withLock { held = true } }

    /// Lets the blocked callers return, and later ones through.
    public func release() {
        condition.withLock {
            held = false
            condition.broadcast()
        }
    }

    /// True once a blocked call had to be let go by the limit: nobody released it in time.
    public var expired: Bool { condition.withLock { _expired } }
    /// Callers blocked right now.
    public var waiting: Int { condition.withLock { _waiting } }

    /// Blocks the calling thread while held (never call it on a thread of the Swift concurrency pool).
    public func wait() {
        condition.withLock {
            guard held else { return }
            _waiting += 1
            defer { _waiting -= 1 }
            let deadline = Date(timeIntervalSinceNow: limit)
            while held {
                if !condition.wait(until: deadline) {
                    _expired = true
                    held = false
                    condition.broadcast()
                    return
                }
            }
        }
    }
}
