import Foundation
import Synchronization
import whisper

/// Errors from the llama.cpp runtime.
public enum LlamaError: Error, Equatable, Sendable {
    /// The GGUF file does not exist.
    case modelMissing(String)
    /// llama.cpp could not load the model (bad or unsupported GGUF, not enough memory).
    case loadFailed(String)
    /// llama.cpp could not create a context for the model.
    case contextFailed(String)
    /// `complete` was called with no model loaded.
    case notLoaded
    /// The prompt could not be tokenized.
    case tokenizeFailed
    /// The prompt alone does not fit in the context (`limit` tokens). Shorten it (e.g. drop history).
    case promptTooLong(tokens: Int, limit: Int)
    /// `llama_decode` failed with this status.
    case decodeFailed(Int32)
    /// `LlamaRuntime.shutdown()` ran; no model can be loaded any more in this process.
    case shutDown
}

/// Set from any thread to stop a running completion between tokens (and inside `llama_decode` through the abort callback).
final class LlamaCancelFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    func cancel() { flag.store(true, ordering: .relaxed) }
    var isCancelled: Bool { flag.load(ordering: .relaxed) }
}

/// One loaded model with its context and greedy sampler. Not thread-safe: `LlamaTextCompleter` uses it only on its serial
/// queue. `deinit` frees the sampler, the context and then the model, which releases every Metal buffer (see
/// `LlamaRuntime` for why that matters at exit).
final class LlamaSession {
    let modelPath: String
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>

    init(modelPath: String, configuration: LlamaTextCompleter.Configuration) throws {
        LlamaRuntime.initializeBackend()
        guard FileManager.default.fileExists(atPath: modelPath) else { throw LlamaError.modelMissing(modelPath) }
        let name = URL(fileURLWithPath: modelPath).lastPathComponent

        var modelParams = llama_model_default_params()
        let loaded: OpaquePointer?
        if configuration.useGPU {
            modelParams.n_gpu_layers = -1   // all layers
            loaded = llama_model_load_from_file(modelPath, modelParams)
        } else {
            // CPU only: no offload devices at all (an empty, NULL-terminated list), so Metal is not used for weights.
            modelParams.n_gpu_layers = 0
            var noDevices: [ggml_backend_dev_t?] = [nil]
            loaded = noDevices.withUnsafeMutableBufferPointer { devices in
                modelParams.devices = devices.baseAddress
                return llama_model_load_from_file(modelPath, modelParams)
            }
        }
        guard let model = loaded else { throw LlamaError.loadFailed(name) }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(configuration.contextLength)
        contextParams.n_batch = UInt32(configuration.batchSize)
        contextParams.n_ubatch = UInt32(min(configuration.batchSize, 512))
        contextParams.n_seq_max = 1
        contextParams.n_threads = Int32(configuration.threads)
        contextParams.n_threads_batch = Int32(configuration.threads)
        contextParams.no_perf = true
        if !configuration.useGPU {
            contextParams.offload_kqv = false
            contextParams.op_offload = false
        }
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LlamaError.contextFailed(name)
        }
        guard let vocab = llama_model_get_vocab(model),
              let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            llama_free(context)
            llama_model_free(model)
            throw LlamaError.contextFailed(name)
        }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        self.modelPath = modelPath
        self.model = model
        self.context = context
        self.vocab = vocab
        self.sampler = sampler
    }

    deinit {
        llama_sampler_free(sampler)
        llama_free(context)
        llama_model_free(model)
    }

    var contextLength: Int { Int(llama_n_ctx(context)) }

    /// Greedy completion from a cleared KV cache. Throws `CancellationError` when `cancel` is set.
    func complete(prompt: String, stop: [String], maxTokens: Int, cancel: LlamaCancelFlag) throws -> String {
        guard maxTokens > 0 else { return "" }
        var tokens = try tokenize(prompt)
        let limit = contextLength
        // At least one token must be generated after the prompt.
        guard tokens.count < limit else { throw LlamaError.promptTooLong(tokens: tokens.count, limit: limit) }

        llama_memory_clear(llama_get_memory(context), true)
        llama_sampler_reset(sampler)
        let cancelPointer = Unmanaged.passUnretained(cancel).toOpaque()
        llama_set_abort_callback(context, llamaAbortCallback, cancelPointer)
        defer { llama_set_abort_callback(context, nil, nil) }

        // The prompt, in pieces of at most n_batch tokens.
        let batchSize = max(1, Int(llama_n_batch(context)))
        var start = 0
        while start < tokens.count {
            if cancel.isCancelled { throw CancellationError() }
            let count = min(batchSize, tokens.count - start)
            let status = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress! + start, Int32(count)))
            }
            try check(status, cancel)
            start += count
        }

        var scanner = StopScanner(stops: stop)
        var position = tokens.count
        var generated = 0
        var piece = [CChar](repeating: 0, count: 64)
        while true {
            if cancel.isCancelled { throw CancellationError() }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            generated += 1
            // special = true: PFML3 control tokens (<|plamo:tag|> …) come out as text so the stop strings can match them.
            var length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, true)
            if length < 0 {
                piece = [CChar](repeating: 0, count: Int(-length))
                length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, true)
            }
            if length > 0, scanner.append(piece[..<Int(length)].lazy.map { UInt8(bitPattern: $0) }) { break }
            // The sampled token goes into the KV cache at `position` (0-based), which must be inside the context.
            guard generated < maxTokens, position < limit else { break }
            let status = withUnsafeMutablePointer(to: &token) { llama_decode(context, llama_batch_get_one($0, 1)) }
            try check(status, cancel)
            position += 1
        }
        tokens.removeAll()
        return scanner.text
    }

    private func check(_ status: Int32, _ cancel: LlamaCancelFlag) throws {
        guard status != 0 else { return }
        if status == 2 || cancel.isCancelled { throw CancellationError() }   // 2 = aborted by the abort callback
        throw LlamaError.decodeFailed(status)
    }

    /// Tokenizes with BOS added (`add_special`) and PFML3 special tokens parsed (`parse_special`).
    private func tokenize(_ text: String) throws -> [llama_token] {
        let byteCount = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(byteCount) + 8)
        var count = llama_tokenize(vocab, text, byteCount, &tokens, Int32(tokens.count), true, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, byteCount, &tokens, Int32(tokens.count), true, true)
        }
        guard count > 0 else { throw LlamaError.tokenizeFailed }
        tokens.removeSubrange(Int(count)...)
        return tokens
    }
}

/// `ggml_abort_callback`: true stops the running graph computation.
private func llamaAbortCallback(_ data: UnsafeMutableRawPointer?) -> Bool {
    guard let data else { return false }
    return Unmanaged<LlamaCancelFlag>.fromOpaque(data).takeUnretainedValue().isCancelled
}
