import AutoNoteCore
import Foundation

/// `autonote dev transcribe` — runs one engine on a file or the microphone and prints one JSON line per
/// utterance (`wall` = wall-clock seconds since input started), then a `summary` line. Live engines get the file
/// as 0.1 s `AudioChunk`s (paced with `--realtime`); `whisper` is the batch path. `--text-out` writes the final
/// utterances joined with no separator (for `scripts/cer.py`). Whisper model load happens before input starts,
/// so `elapsed` / `rtf` exclude it. Exit codes: 0 ok, 1 error, 2 usage, 3 engine unavailable
/// (`unavailable: <reason>` on stderr).
enum DevTranscribe {
    static let usage = """
        usage: autonote dev transcribe <audio> --engine dictation|speech|whisper|whisper-live \
        [--model <name> | --model-path <ggml.bin>] [--data <dir>] [--lang ja|en|auto] [--hints "w1,w2"] [--realtime] \
        [--segmentation default|frequent|silence] [--max-seconds N] [--gpu on|off] [--text-out <path>]
               autonote dev transcribe --mic --engine dictation|speech|whisper-live --seconds N [same options]
               (--mic uses the default input; the first run may ask for microphone permission)
        """

    private enum Engine: String { case dictation, speech, whisper, whisperLive = "whisper-live" }

    private struct Options {
        var file: URL?
        var mic = false
        var seconds: Double?
        var engine: Engine?
        var model: String?
        var modelPath: URL?
        var data: URL?
        var language = Language.ja
        var hints: [String] = []
        var realtime = false
        var segmentation = SegmentationStrategy.current
        var maxSeconds: Double?
        var gpu: Bool?
        var textOut: URL?
    }

    private struct Unavailable: Error { var reason: String }

    private struct Line: Encodable {
        var wall: Double
        var start: Double
        var end: Double?
        var final: Bool
        var text: String

        func encode(to encoder: any Encoder) throws {   // `end` is written as null for partial results
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(wall, forKey: .wall)
            try c.encode(start, forKey: .start)
            try c.encode(end, forKey: .end)
            try c.encode(final, forKey: .final)
            try c.encode(text, forKey: .text)
        }

        private enum CodingKeys: String, CodingKey { case wall, start, end, final, text }
    }

    private struct Summary: Encodable {
        var engine: String
        var audioSeconds: Double
        var elapsed: Double
        var rtf: Double
        var finals: Int
    }

    private struct SummaryLine: Encodable { var summary: Summary }

    static func run(_ args: [String]) async -> Int32 {
        guard let options = parse(args), let engine = options.engine else { return DevCommands.usageError(usage) }
        do {
            let finals: [String]
            let audioSeconds: Double
            let clock = ContinuousClock()
            let startedAt: ContinuousClock.Instant
            if engine == .whisper {
                let batch = try await makeBatch(options)
                let input = try await batchInput(options)
                defer { for url in input.temporary { try? FileManager.default.removeItem(at: url) } }
                audioSeconds = Double(input.samples) / PCMAudio.sampleRate
                startedAt = clock.now
                let utterances = try await batch.transcribe(file: input.file, language: options.language, hints: options.hints) { _ in }
                let wall = seconds(clock.now - startedAt)
                for u in utterances { emit(u, wall: wall) }
                finals = utterances.filter(\.isFinal).map(\.text)
            } else {
                let live = try await makeLive(engine, options)
                let stream = try await live.start(language: options.language, hints: options.hints)
                let liveStart = clock.now
                startedAt = liveStart
                let printer = Task {
                    var texts: [String] = []
                    for await u in stream {
                        emit(u, wall: seconds(clock.now - liveStart))
                        if u.isFinal { texts.append(u.text) }
                    }
                    return texts
                }
                do {
                    if options.mic {
                        audioSeconds = try await feedMic(live, seconds: options.seconds ?? 0)
                    } else {
                        let samples = try fileInput(options)
                        audioSeconds = Double(samples.count) / PCMAudio.sampleRate
                        // --realtime: chunk i is fed at liveStart + i * 0.1 s, so processing time never accumulates.
                        for (index, chunk) in PCMAudio.chunks(samples, track: .mic, chunkSeconds: 0.1, start: TimelineTime(seconds: 0)).enumerated() {
                            if options.realtime { try? await clock.sleep(until: liveStart + .milliseconds(100 * index)) }
                            await live.feed(chunk)
                        }
                    }
                } catch {
                    await live.finish()   // tear the engine down before exiting non-zero
                    _ = await printer.value
                    throw error
                }
                await live.finish()
                finals = await printer.value
            }
            let elapsed = seconds(clock.now - startedAt)
            writeLine(SummaryLine(summary: Summary(engine: engine.rawValue, audioSeconds: round3(audioSeconds), elapsed: round3(elapsed),
                                                   rtf: audioSeconds > 0 ? round3(elapsed / audioSeconds) : 0, finals: finals.count)))
            if let textOut = options.textOut {
                try Data(finals.joined().utf8).write(to: textOut, options: .atomic)
            }
            return 0
        } catch let error as Unavailable {
            DevCommands.printError("unavailable: \(error.reason)")
            return 3
        } catch let error as TranscriptionError {
            switch error {
            case .engineUnavailable(let reason):
                DevCommands.printError("unavailable: \(reason)"); return 3
            case .localeUnsupported(let language):
                DevCommands.printError("unavailable: language \(language.rawValue) is not supported by \(engine.rawValue)"); return 3
            case .modelMissing(let name) where name == options.modelPath?.path:
                DevCommands.printError("error: model file not found: \(name)"); return 1
            case .modelMissing(let name):
                DevCommands.printError("unavailable: model \(name) is not downloaded (autonote dev models download \(name))"); return 3
            default:
                DevCommands.printError("error: \(error)"); return 1
            }
        } catch {
            DevCommands.printError("error: \(error)")
            return 1
        }
    }

    // MARK: - Arguments

    private static func parse(_ args: [String]) -> Options? {
        var o = Options()
        var index = 0
        while index < args.count {
            let arg = args[index]
            let flags: Set<String> = ["--mic", "--realtime"]
            if flags.contains(arg) {
                if arg == "--mic" { o.mic = true } else { o.realtime = true }
                index += 1
                continue
            }
            guard arg.hasPrefix("--") else {
                guard o.file == nil else { return nil }
                o.file = URL(filePath: arg); index += 1
                continue
            }
            guard index + 1 < args.count else { return nil }
            let value = args[index + 1]
            switch arg {
            case "--engine": guard let e = Engine(rawValue: value) else { return nil }; o.engine = e
            case "--model": o.model = value
            case "--model-path": o.modelPath = URL(filePath: value)
            case "--data": o.data = URL(filePath: value, directoryHint: .isDirectory)
            case "--lang": guard let l = Language(rawValue: value) else { return nil }; o.language = l
            case "--hints":
                o.hints = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "--segmentation": guard let s = SegmentationStrategy(rawValue: value) else { return nil }; o.segmentation = s
            case "--max-seconds": guard let n = Double(value), n > 0 else { return nil }; o.maxSeconds = n
            case "--seconds": guard let n = Double(value), n > 0 else { return nil }; o.seconds = n
            case "--gpu":
                switch value { case "on": o.gpu = true; case "off": o.gpu = false; default: return nil }
            case "--text-out": o.textOut = URL(filePath: value)
            default: return nil
            }
            index += 2
        }
        guard let engine = o.engine, o.model == nil || o.modelPath == nil else { return nil }
        if o.mic {
            guard o.file == nil, o.seconds != nil, engine != .whisper else { return nil }
        } else {
            guard o.file != nil, o.seconds == nil else { return nil }
        }
        return o
    }

    // MARK: - Engines

    private static func factory(_ o: Options, machine: MachineKind) -> TranscriberFactory {
        let paths = o.data.map { AppPaths(root: $0) } ?? AppPaths.resolve()
        return TranscriberFactory(models: ModelManager(directory: paths.modelsDirectory), machine: machine, segmentation: o.segmentation)
    }

    /// `--gpu on` loads whisper with Metal (what Apple Silicon does), `off` without; default follows the machine.
    private static func whisperMachine(_ o: Options) -> MachineKind {
        o.gpu.map { $0 ? .appleSilicon : .intel } ?? MachineKind.current()
    }

    private static func makeBatch(_ o: Options) async throws -> any BatchTranscriber {
        let machine = whisperMachine(o)
        if let path = try modelPath(o) {
            return try TranscriberFactory.whisperBatch(modelURL: path, machine: machine, gate: BatchGate(),
                                                       log: { DevCommands.printError($0) })
        }
        let model = o.model ?? EngineCatalog.defaults(for: MachineKind.current()).batch.model ?? "large-v3-turbo"
        return try await factory(o, machine: machine).makeBatch(.whisper(model), gate: BatchGate())
    }

    /// `engine` is a live engine (`--engine whisper` takes the batch path in `run`).
    private static func makeLive(_ engine: Engine, _ o: Options) async throws -> any LiveTranscriber {
        if engine == .whisperLive {
            let machine = whisperMachine(o)
            if let path = try modelPath(o) { return try TranscriberFactory.whisperLive(modelURL: path, machine: machine) }
            let model = o.model ?? EngineCatalog.defaults(for: MachineKind.current()).whisperLiveModel
            return try await factory(o, machine: machine).makeLive(.whisper(model))
        }
        let choice: EngineChoice = engine == .dictation ? .dictation : .speech
        let machine = MachineKind.current()
        let catalog = EngineCatalog(machine: machine, speech: AppleSpeechCapabilities(), installedModels: { @Sendable in [] })
        let entry = await catalog.entries(role: .live, language: o.language).first { $0.choice == choice }
        if let entry, !entry.available { throw Unavailable(reason: entry.reason ?? "\(engine.rawValue) is not available") }
        return try await factory(o, machine: machine).makeLive(choice)
    }

    private static func modelPath(_ o: Options) throws -> URL? {
        guard let path = o.modelPath else { return nil }
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw TranscriptionError.modelMissing(path.path)
        }
        return path
    }

    // MARK: - Input

    /// The batch path's input as a 16 kHz mono 16-bit WAV, never held whole in memory: the original file when it is
    /// already that format, otherwise a temporary conversion; cut to `--max-seconds` by copying ranged reads into
    /// another temporary WAV. `temporary` lists the files the caller deletes.
    private static func batchInput(_ o: Options) async throws -> (file: URL, samples: Int, temporary: [URL]) {
        guard let source = o.file else { throw TranscriptionError.invalidAudio("no input file") }
        var temporary: [URL] = []
        do {
            var file = source
            var samples: Int
            if let info = try? WAVFile.info(source), info.sampleRate == Int(PCMAudio.sampleRate), info.channels == 1,
               info.bitsPerSample == 16 {
                samples = try WAVFile.sampleCount(source)
            } else {
                file = temporaryWAV()
                temporary.append(file)
                samples = try await AudioImporter.convertToMono16kWAV(from: source, to: file)
            }
            if let max = o.maxSeconds, samples > Int(max * PCMAudio.sampleRate) {
                let cut = Int(max * PCMAudio.sampleRate)
                let copy = temporaryWAV()
                temporary.append(copy)
                try WAVFile.header(sampleRate: Int(PCMAudio.sampleRate), channels: 1, bitsPerSample: 16, dataBytes: cut * 2)
                    .write(to: copy)
                let handle = try FileHandle(forWritingTo: copy)
                defer { try? handle.close() }
                try handle.seekToEnd()
                let step = 960_000   // 60 s
                for lower in stride(from: 0, to: cut, by: step) {
                    let chunk = try WAVFile.readSamples(file, in: lower..<min(lower + step, cut))
                    try handle.write(contentsOf: chunk.withUnsafeBytes { Data($0) })
                }
                file = copy
                samples = cut
            }
            return (file, samples, temporary)
        } catch {
            for url in temporary { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private static func temporaryWAV() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "autonote-dev-transcribe-\(UUID().uuidString).wav")
    }

    /// Reads the input as 16 kHz mono, cut to `--max-seconds` (live engines only; whisper uses `batchInput`).
    private static func fileInput(_ o: Options) throws -> [Int16] {
        guard let file = o.file else { throw TranscriptionError.invalidAudio("no input file") }
        let samples = try PCMAudio.readMono16k(file)
        guard let max = o.maxSeconds, samples.count > Int(max * PCMAudio.sampleRate) else { return samples }
        return Array(samples.prefix(Int(max * PCMAudio.sampleRate)))
    }

    /// Feeds the microphone for `seconds`, then returns the seconds captured.
    private static func feedMic(_ live: any LiveTranscriber, seconds: Double) async throws -> Double {
        let mic = try DevMicCapture()
        let (chunks, sink) = AsyncStream<AudioChunk>.makeStream()
        let feeder = Task { for await chunk in chunks { await live.feed(chunk) } }
        try mic.start { sink.yield($0) }
        try? await Task.sleep(for: .seconds(seconds))
        mic.stop()
        sink.finish()
        await feeder.value
        return mic.capturedSeconds
    }

    // MARK: - Output

    private static func emit(_ u: Utterance, wall: Double) {
        writeLine(Line(wall: round3(wall), start: round3(u.start.seconds), end: u.end.map { round3($0.seconds) },
                       final: u.isFinal, text: u.text))
    }

    private static func writeLine(_ value: some Encodable) {
        guard let data = try? AutoNoteJSON.compactEncoder().encode(value) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    private static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}
