import AutoNoteTestSupport
import Foundation
import Testing
@testable import AutoNoteCore

/// PLaMo 3 Translate GGUF files for the real-model tests, separated by ":" (e.g. the 0.8B and 2B Q4_K_M from
/// ~/Library/Caches/autonote-plamo-spike/models/pfnet/). Unset or missing files: those tests are skipped.
private let plamoModels: [String] = (ProcessInfo.processInfo.environment["AUTONOTE_TEST_PLAMO_MODELS"] ?? "")
    .split(separator: ":").map(String.init).filter { FileManager.default.fileExists(atPath: $0) }

private let stops = ["<|plamo:tag|>", "<|plamo:bos|>"]

/// The basic PFML3 prompt (docs/superpowers/research/2026-11-14-plamo-3-translate-spike.md §1). BOS is added by the tokenizer.
private func pfml3(_ text: String, from source: String, to target: String) -> String {
    let (t, m, k, v) = ("<|plamo:tag|>", "<|plamo:msg|>", "<|plamo:key|>", "<|plamo:val|>")
    return "\(t)dataset\(m)translation\(t)input\(k)lang\(v)\(source)\(m)\(text)\(t)output\(k)lang\(v)\(target)\(m)"
}

private func completer() -> LlamaTextCompleter {
    LlamaTextCompleter(configuration: .automatic())
}

@Suite struct LlamaTextCompleterTests {
    @Test func llamaIsLinkedWithTheSharedGGML() {
        LlamaRuntime.initializeBackend()
        #expect(!WhisperRuntime.systemInfo().isEmpty)
        #expect(LlamaRuntime.maxDevices >= 1)
    }

    @Test func automaticConfigurationUsesMetalOnlyOnAppleSilicon() {
        let intel = MachineProfile(kind: .intel, physicalCores: 4, physicalMemory: 8 << 30)
        let silicon = MachineProfile(kind: .appleSilicon, physicalCores: 10, physicalMemory: 16 << 30)
        #expect(LlamaTextCompleter.Configuration.automatic(profile: intel) == .init(useGPU: false, threads: 3))
        #expect(LlamaTextCompleter.Configuration.automatic(profile: silicon) == .init(useGPU: true, threads: 4))
        #expect(LlamaTextCompleter.Configuration(contextLength: 10, batchSize: 0, useGPU: true, threads: 0)
            == .init(contextLength: 256, batchSize: 1, useGPU: true, threads: 1))
    }

    @Test func missingModelThrows() async {
        let path = "/nonexistent/autonote/plamo-missing.gguf"
        let llama = completer()
        await #expect(throws: LlamaError.modelMissing(path)) {
            try await llama.load(modelURL: URL(fileURLWithPath: path))
        }
        #expect(await llama.loadedModelPath == nil)
    }

    @Test func notAGGUFFails() async throws {
        let dir = try TemporaryDirectory.make()
        let file = dir.appending(path: "broken.gguf")
        try Data("not a gguf".utf8).write(to: file)
        let llama = completer()
        await #expect(throws: LlamaError.loadFailed("broken.gguf")) {
            try await llama.load(modelURL: file)
        }
    }

    @Test func completeWithoutModelThrows() async {
        let llama = completer()
        await #expect(throws: LlamaError.notLoaded) {
            _ = try await llama.complete(prompt: "x", stop: stops, maxTokens: 4)
        }
    }

    @Test func unloadWithoutModelIsSafe() async {
        let llama = completer()
        await llama.unload()
        await llama.unload()
        #expect(await llama.loadedModelPath == nil)
    }

    @Test func alreadyCancelledTaskThrowsBeforeRunning() async {
        let llama = completer()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await llama.complete(prompt: "x", stop: stops, maxTokens: 4)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

/// Real PLaMo 3 Translate models. Serialized: each loads a model (0.6–1.8 GB) on Metal.
@Suite(.serialized, .enabled(if: !plamoModels.isEmpty)) struct LlamaTextCompleterRealModelTests {
    @Test(arguments: plamoModels)
    func translatesJapaneseToEnglishAndStopsAtTheTag(model: String) async throws {
        let llama = completer()
        try await llama.load(modelURL: URL(fileURLWithPath: model))
        let result = await Result {
            try await llama.complete(prompt: pfml3("会議は来週の月曜日に変更されました。", from: "ja", to: "en"), stop: stops, maxTokens: 64)
        }
        await llama.unload()
        let english = try result.get()
        #expect(english.lowercased().contains("meeting"), "\(english)")
        #expect(english.contains("Monday"), "\(english)")
        #expect(!english.contains("<|plamo"), "\(english)")
        #expect(english.count < 120, "\(english)")   // stopped at the tag, not at maxTokens
    }

    @Test(arguments: plamoModels)
    func translatesEnglishToJapaneseDeterministically(model: String) async throws {
        let llama = completer()
        try await llama.load(modelURL: URL(fileURLWithPath: model))
        let prompt = pfml3("The meeting has been moved to next Monday.", from: "en", to: "ja")
        let result = await Result {
            (try await llama.complete(prompt: prompt, stop: stops, maxTokens: 64),
             try await llama.complete(prompt: prompt, stop: stops, maxTokens: 64))
        }
        await llama.unload()
        let (first, second) = try result.get()
        #expect(first.contains("月曜"), "\(first)")
        #expect(first == second)   // greedy from a cleared KV cache
    }

    @Test(arguments: plamoModels)
    func customStopStringAndMaxTokens(model: String) async throws {
        let llama = completer()
        try await llama.load(modelURL: URL(fileURLWithPath: model))
        let prompt = pfml3("会議は来週の月曜日に変更されました。", from: "ja", to: "en")
        let result = await Result {
            (full: try await llama.complete(prompt: prompt, stop: stops, maxTokens: 64),
             cut: try await llama.complete(prompt: prompt, stop: ["Monday"] + stops, maxTokens: 64),
             short: try await llama.complete(prompt: prompt, stop: stops, maxTokens: 2),
             none: try await llama.complete(prompt: prompt, stop: stops, maxTokens: 0))
        }
        await llama.unload()
        let r = try result.get()
        #expect(r.full.hasPrefix(r.cut) && !r.cut.contains("Monday") && r.cut.count < r.full.count, "\(r)")
        #expect(r.full.hasPrefix(r.short) && r.short.count < r.full.count, "\(r)")
        #expect(r.none.isEmpty)
    }

    @Test(arguments: plamoModels)
    func reloadsAfterUnloadAndSwitchesModels(model: String) async throws {
        let llama = completer()
        let url = URL(fileURLWithPath: model)
        let prompt = pfml3("ありがとうございます。", from: "ja", to: "en")
        try await llama.load(modelURL: url)
        try await llama.load(modelURL: url)   // already loaded: no-op
        let before = await Result { try await llama.complete(prompt: prompt, stop: stops, maxTokens: 32) }
        await llama.unload()
        #expect(await llama.loadedModelPath == nil)
        await #expect(throws: LlamaError.notLoaded) {
            _ = try await llama.complete(prompt: prompt, stop: stops, maxTokens: 32)
        }
        try await llama.load(modelURL: url)
        #expect(await llama.loadedModelPath == url.standardizedFileURL.path)
        let after = await Result { try await llama.complete(prompt: prompt, stop: stops, maxTokens: 32) }
        // Switching to another model frees the current one first.
        if let other = plamoModels.first(where: { $0 != model }) {
            try await llama.load(modelURL: URL(fileURLWithPath: other))
            #expect(await llama.loadedModelPath == URL(fileURLWithPath: other).standardizedFileURL.path)
        }
        await llama.unload()
        #expect(try before.get() == after.get())
        #expect(try !before.get().isEmpty)
    }

    @Test(arguments: plamoModels)
    func cancellingTheTaskStopsAndTheCompleterStaysUsable(model: String) async throws {
        let llama = completer()
        try await llama.load(modelURL: URL(fileURLWithPath: model))
        // A long input with no stop strings: hundreds of tokens, far longer than the 100 ms before the cancel.
        let long = String(repeating: "来週の月曜日に会議があります。資料は前日までに共有してください。", count: 40)
        let prompt = pfml3(long, from: "ja", to: "en")
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task { try await llama.complete(prompt: prompt, stop: [], maxTokens: 3000) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let outcome = await task.result
        let elapsed = clock.now - started
        let after = await Result {
            try await llama.complete(prompt: pfml3("はい。", from: "ja", to: "en"), stop: stops, maxTokens: 16)
        }
        await llama.unload()
        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(elapsed < .seconds(2), "\(elapsed)")
        #expect(try !after.get().isEmpty)
    }

    @Test(arguments: plamoModels)
    func unloadCancelsARunningCompletion(model: String) async throws {
        let llama = completer()
        try await llama.load(modelURL: URL(fileURLWithPath: model))
        let long = String(repeating: "来週の月曜日に会議があります。資料は前日までに共有してください。", count: 40)
        let task = Task { try await llama.complete(prompt: pfml3(long, from: "ja", to: "en"), stop: [], maxTokens: 3000) }
        try await Task.sleep(for: .milliseconds(100))
        await llama.unload()
        let outcome = await task.result
        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(await llama.loadedModelPath == nil)
    }

    @Test(arguments: plamoModels)
    func cpuOnlyTranslatesToo(model: String) async throws {
        let llama = LlamaTextCompleter(configuration: .init(useGPU: false, threads: 4))
        try await llama.load(modelURL: URL(fileURLWithPath: model))
        let result = await Result {
            try await llama.complete(prompt: pfml3("会議は来週の月曜日に変更されました。", from: "ja", to: "en"), stop: stops, maxTokens: 64)
        }
        await llama.unload()
        #expect(try result.get().contains("Monday"))
    }
}

private extension Result where Failure == any Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
