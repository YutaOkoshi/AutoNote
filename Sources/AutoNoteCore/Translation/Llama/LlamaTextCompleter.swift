import Foundation
import Synchronization
import whisper

/// The real `TextCompleting` on llama.cpp (the same ggml as whisper.cpp, in the `whisper` XCFramework).
///
/// Every model operation runs on one private serial queue (never on the cooperative thread pool), so `load`,
/// `complete` and `unload` never overlap and the model is never freed under a running completion. `unload` (and
/// `LlamaRuntime.shutdown()`) first cancel every waiting or running completion, which then throws `CancellationError`.
public final class LlamaTextCompleter: TextCompleting, @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Context size in tokens (prompt + generated text). A PFML3 prompt with 3 history pairs is ~150–1,500 tokens.
        public var contextLength: Int
        /// Prompt tokens decoded per `llama_decode` call.
        public var batchSize: Int
        /// Metal offload. Off on Intel, where Metal output is broken (the same rule as Whisper).
        public var useGPU: Bool
        /// CPU threads for decoding.
        public var threads: Int

        public init(contextLength: Int = 4096, batchSize: Int = 2048, useGPU: Bool, threads: Int) {
            self.contextLength = max(256, contextLength)
            self.batchSize = max(1, batchSize)
            self.useGPU = useGPU
            self.threads = max(1, threads)
        }

        /// Metal on Apple Silicon only; the automatic batch threads (physical cores − 1, 1...4).
        public static func automatic(profile: MachineProfile = .current()) -> Configuration {
            Configuration(useGPU: profile.kind == .appleSilicon, threads: profile.batchThreads(setting: nil))
        }
    }

    public let configuration: Configuration
    private let queue = DispatchQueue(label: "com.yutaokoshi.autonote.llama", qos: .utility)
    /// Only touched on `queue`.
    private var session: LlamaSession?
    /// Completions that were called and have not returned yet (waiting for or running on `queue`).
    private let pending = Mutex<[ObjectIdentifier: LlamaCancelFlag]>([:])

    public init(configuration: Configuration = .automatic()) {
        self.configuration = configuration
        LlamaRuntime.register(self)
    }

    /// The path of the loaded model, nil when nothing is loaded.
    public var loadedModelPath: String? {
        get async { await onQueue { self.session?.modelPath } }
    }

    public func load(modelURL: URL) async throws {
        let path = modelURL.standardizedFileURL.path
        try await onQueue {
            guard !LlamaRuntime.isShutDown else { throw LlamaError.shutDown }
            if self.session?.modelPath == path { return }
            self.session = nil   // free the current model before loading the next one (memory)
            self.session = try LlamaSession(modelPath: path, configuration: self.configuration)
        }
    }

    public func complete(prompt: String, stop: [String], maxTokens: Int) async throws -> String {
        try Task.checkCancellation()
        let flag = LlamaCancelFlag()
        let key = ObjectIdentifier(flag)
        pending.withLock { $0[key] = flag }
        defer { pending.withLock { _ = $0.removeValue(forKey: key) } }
        return try await withTaskCancellationHandler {
            try await onQueue {
                if flag.isCancelled { throw CancellationError() }
                guard let session = self.session else { throw LlamaError.notLoaded }
                return try session.complete(prompt: prompt, stop: stop, maxTokens: maxTokens, cancel: flag)
            }
        } onCancel: {
            flag.cancel()
        }
    }

    public func unload() async {
        cancelPending()
        await onQueue { self.session = nil }
    }

    /// Cancels every pending completion and frees the model before returning (blocks the caller). For
    /// `LlamaRuntime.shutdown()`; must not be called on `queue`.
    func unloadNow() {
        cancelPending()
        queue.sync { session = nil }
    }

    private func cancelPending() {
        pending.withLock { flags in flags.values.forEach { $0.cancel() } }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

/// Process-wide llama.cpp state: backend initialization and the shutdown path.
///
/// ggml's Metal device is a C++ static. When the process exits, its destructor asserts that every Metal buffer has
/// been freed (`ggml-metal-device.m: GGML_ASSERT([rsets->data count] == 0)`) and aborts otherwise — for llama and
/// whisper contexts alike, since both share the one ggml in the XCFramework. So before the app exits, every llama
/// model must be freed (`shutdown()`), and every whisper context must be released (Whisper does that through ARC when
/// the recording/transcription that owns it ends).
public enum LlamaRuntime {
    private static let backend: Void = {
        WhisperRuntime.installQuietLogging()
        llama_backend_init()
    }()

    static func initializeBackend() { _ = backend }

    /// llama.cpp's device limit (links against the XCFramework's llama; used by the link test).
    static var maxDevices: Int { Int(llama_max_devices()) }

    private final class WeakCompleter: @unchecked Sendable {
        weak var value: LlamaTextCompleter?
        init(_ value: LlamaTextCompleter) { self.value = value }
    }

    private static let completers = Mutex<[WeakCompleter]>([])
    private static let shutDown = Atomic<Bool>(false)

    static func register(_ completer: LlamaTextCompleter) {
        completers.withLock { list in
            list.removeAll { $0.value == nil }
            list.append(WeakCompleter(completer))
        }
    }

    /// True after `shutdown()`: loading a model throws `LlamaError.shutDown`.
    public static var isShutDown: Bool { shutDown.load(ordering: .relaxed) }

    /// Frees every loaded llama model now (synchronously) and refuses later loads. Running completions are cancelled
    /// and stop within a token. Call it from `applicationWillTerminate` (any thread except a completer's own queue),
    /// before the process exits. Idempotent.
    public static func shutdown() {
        shutDown.store(true, ordering: .relaxed)
        let live = completers.withLock { list in list.compactMap(\.value) }
        live.forEach { $0.unloadNow() }
    }
}
