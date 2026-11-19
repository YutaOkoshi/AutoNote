import AutoNoteCore
import AutoNoteTestSupport
import Foundation

/// `autonote dev translate` — translates a transcript JSON (the `Transcript` shape of `final.json`) and prints one JSON
/// line `{"entries":[{"index","source_lang","target_lang","text"}],"model","skipped","target","utterances"}` (with
/// `--minutes` / `--live-summary`, also `"minutes"` / `"live_summary"`:
/// `{"entries":[{"source","source_lang","target_lang","text"}],"summary_lang","target_lang"}`). Uses the
/// deterministic `FakeTextCompleter` (`"EN: <text>"` / `"JA: <text>"`) unless `--model <gguf>` names a real model,
/// which needs the on-device runtime (`TranslationRuntimeFactory`). Exit codes: 0 done, 1 error, 2 usage.
enum DevTranslate {
    static let usage = DevTranslateArguments.usage

    static func run(_ args: [String]) async -> Int32 {
        let options: DevTranslateArguments
        do { options = try DevTranslateArguments.parse(args) } catch {
            return DevCommands.usageError(usage)
        }
        do {
            let transcript = try AutoNoteJSON.decoder().decode(Transcript.self, from: Data(contentsOf: options.transcript))
            let minutes = try options.minutes.map {
                try AutoNoteJSON.decoder().decode(MinutesOutput.self, from: Data(contentsOf: $0))
            }
            let liveSummary = try options.liveSummary.map {
                try AutoNoteJSON.decoder().decode(LiveSummaryState.self, from: Data(contentsOf: $0))
            }
            let line: DevTranslateLine
            if let model = options.model {
                guard let runtime = TranslationRuntimeFactory.makeOnDevice() else {
                    DevCommands.printError("error: このビルドには端末内の翻訳エンジン（llama.cpp）が入っていないため、--model は使えません。--model を外すと偽の翻訳器で動きます")
                    return 1
                }
                guard FileManager.default.fileExists(atPath: model.path) else {
                    DevCommands.printError("error: モデルがありません: \(model.path)")
                    return 1
                }
                try await runtime.load(modelURL: model)
                do {
                    line = try await DevTranslateLine.make(transcript: transcript, target: options.target,
                                                           model: model.lastPathComponent, completer: runtime,
                                                           minutes: minutes, liveSummary: liveSummary)
                } catch {
                    await runtime.unload()
                    throw error
                }
                await runtime.unload()
            } else {
                line = try await DevTranslateLine.make(transcript: transcript, target: options.target, model: "fake",
                                                       completer: FakeTextCompleter(), minutes: minutes,
                                                       liveSummary: liveSummary)
            }
            FileHandle.standardOutput.write(try line.encoded() + Data("\n".utf8))
            return 0
        } catch {
            DevCommands.printError("error: \(error)")
            return 1
        }
    }
}
