import Foundation
import os

private let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "TranslationRuntime")

/// The one on-device LLM shared by the live and the post-recording translation. One user at a time (FIFO): a
/// lease loads the model, the holder translates, and the end of the lease unloads it (spec 10: the model is loaded
/// only while used).
public actor TranslationRuntime {
    private let completer: any TextCompleting
    private var held = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    public init(completer: any TextCompleting) { self.completer = completer }

    /// Waits for the runtime, loads `modelURL`, runs `body` and always unloads afterwards. Waiting ends with
    /// `CancellationError` when the task is cancelled.
    public func withModel<T: Sendable>(_ modelURL: URL,
                                       _ body: @Sendable (UtteranceTranslator) async throws -> T) async throws -> T {
        try await acquire()
        do {
            try await completer.load(modelURL: modelURL)
        } catch {
            await completer.unload()
            release()
            throw error
        }
        do {
            let result = try await body(UtteranceTranslator(completer: completer))
            await completer.unload()
            release()
            return result
        } catch {
            await completer.unload()
            release()
            throw error
        }
    }

    /// Unloads whatever is loaded (the app's quit path, after the users were cancelled).
    public func shutdown() async {
        await completer.unload()
        logger.notice("translation runtime unloaded (shutdown)")
    }

    /// Whether someone holds the runtime now (tests).
    public var isHeld: Bool { held }

    private func acquire() async throws {
        guard held else {
            held = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { c.resume(throwing: CancellationError()) } else { waiters.append((id, c)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Hands the runtime to the next waiter, or frees it.
    private func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume(throwing: CancellationError())
    }
}

/// The one place the real runtime (llama.cpp, built by the other half of the feature) is plugged in. The app and
/// `autonote dev translate --model` both ask here; nil means this build has no runtime.
public enum TranslationRuntimeFactory {
    public static func makeOnDevice() -> (any TextCompleting)? {
        nil
    }
}

/// Stands in when the build has no runtime: every load fails with `TranslationError.runtimeUnavailable`, so a
/// translation fails cleanly (and the meeting is untouched) instead of producing anything.
public struct UnavailableTextCompleter: TextCompleting {
    public init() {}
    public func load(modelURL: URL) async throws { throw TranslationError.runtimeUnavailable }
    public func complete(prompt: String, stop: [String], maxTokens: Int) async throws -> String {
        throw TranslationError.runtimeUnavailable
    }
    public func unload() async {}
}
