import Foundation

/// The boundary between the translation feature and the on-device LLM runtime (llama.cpp).
///
/// The translation side builds the whole PLaMo 3 Translate prompt (PFML3) and hands it over as text; the runtime
/// tokenizes it with special tokens parsed, decodes greedily from a cleared KV cache, and returns the generated text
/// up to (not including) the first stop string, or after `maxTokens` tokens.
/// See docs/superpowers/specs/2026-11-14-transcript-translation-design.md.
public protocol TextCompleting: Sendable {
    /// Loads the GGUF model at `modelURL` if it is not loaded yet. Loading another model unloads the current one.
    func load(modelURL: URL) async throws
    /// Greedy completion of `prompt`. Throws `CancellationError` when the task is cancelled between tokens.
    func complete(prompt: String, stop: [String], maxTokens: Int) async throws -> String
    /// Frees the model and its context (Metal resources included). Safe to call when nothing is loaded.
    func unload() async
}
