// ヒントの渡し方（計画 04 Task 5 Step 1）: whisper.cpp に `carry_initial_prompt` があるので (a) を採る。
// `no_context = true`・`carry_initial_prompt = true`・`n_max_text_ctx` は既定のまま（過去の文字起こしは呼び出しをまたいで渡さず、
// ヒントだけを毎回の窓の先頭に付ける）。
import Foundation
import Synchronization
import whisper

/// The real `WhisperCore` on whisper.cpp. The model (`whisper_context`) is loaded once per model file and
/// shared process-wide; each instance owns its own `whisper_state`, so two tracks can decode at once
/// without loading the model twice. `whisper_full_with_state` runs on a private utility queue so it never
/// blocks the cooperative thread pool.
public final class WhisperContext: WhisperCore, @unchecked Sendable {
    /// Threads for batch decoding: `min(4, max(1, activeProcessorCount / 2))`.
    public static var batchThreads: Int { min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)) }

    private let model: SharedModel
    private let state: OpaquePointer
    private let threads: Int32
    private let queue = DispatchQueue(label: "com.yutaokoshi.autonote.whisper", qos: .utility)

    /// - Parameter machine: Metal is used only on Apple Silicon (Intel's Metal output is broken, 要件書 §3.3).
    public init(modelURL: URL, machine: MachineKind, threads: Int) throws {
        model = try SharedModel.load(path: modelURL.path, useGPU: machine == .appleSilicon)
        guard let state = whisper_init_state(model.context) else {
            throw TranscriptionError.engineUnavailable("whisper_init_state failed: \(modelURL.lastPathComponent)")
        }
        self.state = state
        self.threads = Int32(max(1, threads))
    }

    deinit {
        whisper_free_state(state)
    }

    public func run(
        _ r: WhisperRunRequest,
        onSegment: @Sendable @escaping (WhisperSegment, [TimedToken]) -> Void,
        onProgress: @Sendable @escaping (Double) -> Void,
        shouldAbort: @Sendable @escaping () -> Bool
    ) async throws -> WhisperRunOutcome {
        let callbacks = RunCallbacks(mode: r.mode, onSegment: onSegment, onProgress: onProgress, shouldAbort: shouldAbort)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WhisperRunOutcome, Error>) in
                queue.async { [self] in
                    continuation.resume(with: Result { try runSync(r, callbacks) })
                }
            }
        } onCancel: {
            callbacks.cancel()
        }
    }

    /// Runs on `queue`.
    private func runSync(_ r: WhisperRunRequest, _ callbacks: RunCallbacks) throws -> WhisperRunOutcome {
        var params = whisper_full_default_params(r.mode == .batch ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        params.n_threads = threads
        switch r.mode {
        case .batch:
            params.beam_search.beam_size = 5
            params.greedy.best_of = 5
        case .live:
            params.greedy.best_of = 1
            params.token_timestamps = true
        }
        params.offset_ms = Int32((r.offsetSeconds * 1000).rounded())
        params.no_context = true
        params.carry_initial_prompt = true
        params.suppress_blank = true
        params.suppress_nst = true
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false

        let userData = Unmanaged.passUnretained(callbacks).toOpaque()
        params.new_segment_callback = { context, state, newCount, userData in
            guard let context, let state, let userData else { return }
            Unmanaged<RunCallbacks>.fromOpaque(userData).takeUnretainedValue().newSegments(context, state, Int(newCount))
        }
        params.new_segment_callback_user_data = userData
        params.progress_callback = { _, _, percent, userData in
            guard let userData else { return }
            Unmanaged<RunCallbacks>.fromOpaque(userData).takeUnretainedValue().onProgress(Double(percent) / 100)
        }
        params.progress_callback_user_data = userData
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<RunCallbacks>.fromOpaque(userData).takeUnretainedValue().checkAbort()
        }
        params.abort_callback_user_data = userData

        let code = withExtendedLifetime(callbacks) {
            Self.languageCode(r.language).withCString { language in
                withOptionalCString(r.prompt) { prompt in
                    params.language = language
                    params.initial_prompt = prompt
                    return r.samples.withUnsafeBufferPointer { samples in
                        whisper_full_with_state(model.context, state, params, samples.baseAddress, Int32(samples.count))
                    }
                }
            }
        }
        if callbacks.abortRequested { return .aborted }
        if code != 0 { throw TranscriptionError.whisperFailed(code) }
        return .completed
    }

    static func languageCode(_ language: Language) -> String {
        switch language {
        case .ja: "ja"
        case .en: "en"
        case .auto: "auto"
        }
    }
}

private func withOptionalCString<T>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
    guard let string else { return body(nil) }
    return string.withCString { body($0) }
}

/// Bridges whisper's C callbacks (passed through `user_data`) to the Swift closures of one run.
private final class RunCallbacks: @unchecked Sendable {
    let mode: WhisperDecodeMode
    let onSegment: @Sendable (WhisperSegment, [TimedToken]) -> Void
    let onProgress: @Sendable (Double) -> Void
    private let shouldAbort: @Sendable () -> Bool
    private let flags = Mutex((cancelled: false, abortRequested: false))

    init(mode: WhisperDecodeMode, onSegment: @Sendable @escaping (WhisperSegment, [TimedToken]) -> Void,
         onProgress: @Sendable @escaping (Double) -> Void, shouldAbort: @Sendable @escaping () -> Bool) {
        self.mode = mode; self.onSegment = onSegment; self.onProgress = onProgress; self.shouldAbort = shouldAbort
    }

    var abortRequested: Bool { flags.withLock { $0.abortRequested } }

    func cancel() { flags.withLock { $0.cancelled = true } }

    func checkAbort() -> Bool {
        let cancelled = flags.withLock { $0.cancelled }
        guard cancelled || shouldAbort() else { return false }
        flags.withLock { $0.abortRequested = true }
        return true
    }

    /// whisper times are centiseconds and already include `offset_ms`.
    func newSegments(_ context: OpaquePointer, _ state: OpaquePointer, _ newCount: Int) {
        let count = Int(whisper_full_n_segments_from_state(state))
        for i in max(0, count - newCount)..<count {
            let index = Int32(i)
            let segment = WhisperSegment(
                start: Double(whisper_full_get_segment_t0_from_state(state, index)) / 100,
                end: Double(whisper_full_get_segment_t1_from_state(state, index)) / 100,
                text: String(cString: whisper_full_get_segment_text_from_state(state, index))
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            onSegment(segment, mode == .live ? tokens(context, state, index) : [])
        }
    }

    private func tokens(_ context: OpaquePointer, _ state: OpaquePointer, _ segment: Int32) -> [TimedToken] {
        let eot = whisper_token_eot(context)
        return (0..<whisper_full_n_tokens_from_state(state, segment)).compactMap { j in
            let data = whisper_full_get_token_data_from_state(state, segment, j)
            guard data.id < eot, let text = whisper_full_get_token_text_from_state(context, state, segment, j) else { return nil }
            return TimedToken(start: Double(data.t0) / 100, end: Double(data.t1) / 100, text: String(cString: text))
        }
    }
}

/// One loaded `whisper_context` per model path, shared by every `WhisperContext` that uses it and freed
/// when the last one goes away.
private final class SharedModel: @unchecked Sendable {
    let context: OpaquePointer

    private init(context: OpaquePointer) { self.context = context }

    deinit { whisper_free(context) }

    private final class WeakModel { weak var model: SharedModel?; init(_ m: SharedModel) { model = m } }
    private static let cache = Mutex<[String: WeakModel]>([:])

    static func load(path: String, useGPU: Bool) throws -> SharedModel {
        WhisperRuntime.installQuietLogging()
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        return try cache.withLock { cache in
            if let model = cache[key]?.model { return model }
            guard FileManager.default.fileExists(atPath: key) else { throw TranscriptionError.modelMissing(path) }
            var params = whisper_context_default_params()
            params.use_gpu = useGPU
            guard let context = whisper_init_from_file_with_params(key, params) else {
                throw TranscriptionError.engineUnavailable("whisper could not load \(URL(fileURLWithPath: path).lastPathComponent)")
            }
            let model = SharedModel(context: context)
            cache[key] = WeakModel(model)
            return model
        }
    }
}
