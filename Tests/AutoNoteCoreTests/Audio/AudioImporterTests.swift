import Testing
import Foundation
import AVFoundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct AudioImporterTests {
    private struct Env {
        let paths: AppPaths
        let store: ManifestStore
        let importer: AudioImporter
        let inputs: URL
    }

    private func makeEnv() throws -> Env {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let store = ManifestStore(paths: paths)
        return Env(paths: paths, store: store,
                   importer: AudioImporter(paths: paths, manifests: store, timeZone: Samples.tokyo),
                   inputs: try TemporaryDirectory.make())
    }

    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func add(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
        var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
    }

    /// Writes `seconds` of a 440 Hz sine (44.1 kHz, 2 ch). wav = linear PCM, m4a = AAC.
    /// mp4 is the m4a copied to an `.mp4` name (AAC in an MPEG-4 container is the same payload).
    private func synthesize(_ ext: String, in dir: URL, seconds: Double = 3) throws -> URL {
        let sourceExt = ext == "mp4" ? "m4a" : ext
        let url = dir.appending(path: "tone.\(sourceExt)")
        let settings: [String: Any] = sourceExt == "wav"
            ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
               AVEncoderBitRateKey: 64000]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(44100 * seconds)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
            buffer.frameLength = frames
            for ch in 0..<Int(file.processingFormat.channelCount) {
                let p = buffer.floatChannelData![ch]
                for i in 0..<Int(frames) { p[i] = 0.5 * sinf(2 * .pi * 440 * Float(i) / 44100) }
            }
            try file.write(from: buffer)
        }   // AVAudioFile finalizes on deinit
        guard ext == "mp4" else { return url }
        let mp4 = dir.appending(path: "tone.mp4")
        try FileManager.default.copyItem(at: url, to: mp4)
        return mp4
    }

    @Test(arguments: ["wav", "m4a", "mp4"])
    func importsTo16kMonoWAV(ext: String) async throws {
        let env = try makeEnv()
        let input = try synthesize(ext, in: env.inputs)
        let m = try await env.importer.importFile(input, language: .ja)

        let wavURL = env.paths.meetingDirectory(m.id).appending(path: "tracks/import-000.wav")
        let info = try WAVFile.info(wavURL)
        #expect(info.sampleRate == 16000)
        #expect(info.channels == 1)
        #expect(info.bitsPerSample == 16)
        #expect(abs(info.durationSeconds - 3.0) < 0.05)

        #expect(m.source == .imported)
        #expect(m.device == DeviceRef(name: "import", uid: "import", transport: "import"))
        #expect(m.status == .recorded)
        #expect(m.language == .ja)
        #expect(m.pauses.isEmpty && m.bookmarks.isEmpty)
        #expect(m.tracks == [TrackFile(track: .mic, relativePath: "tracks/import-000.wav",
                                       startOffset: TimelineTime(seconds: 0),
                                       durationSeconds: m.tracks.first?.durationSeconds)])
        #expect(abs((m.tracks.first?.durationSeconds ?? 0) - info.durationSeconds) < 0.0001)
        #expect(abs(m.endedAt!.timeIntervalSince(m.startedAt) - info.durationSeconds) < 0.002)
        #expect(try await env.store.load(m.id) == m)   // JSON dates are ms precision; the importer truncates to match
        // The tone survived resampling (not silence).
        let samples = try WAVFile.readSamples(wavURL)
        #expect(samples.contains { abs(Int($0)) > 8000 })
    }

    @Test func acceptsUppercaseExtension() async throws {
        let env = try makeEnv()
        let wav = try synthesize("wav", in: env.inputs, seconds: 1)
        let upper = env.inputs.appending(path: "LOUD.WAV")
        try FileManager.default.moveItem(at: wav, to: upper)
        let m = try await env.importer.importFile(upper, language: .ja)
        #expect(m.status == .recorded)
    }

    @Test func defaultsStartToFileCreationDate() async throws {
        let env = try makeEnv()
        let input = try synthesize("wav", in: env.inputs, seconds: 1)
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Samples.tokyo
        let date = c.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 10, minute: 0))!
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: input.path)
        let m = try await env.importer.importFile(input, language: .en)
        #expect(m.startedAt == date)
        #expect(m.id.rawValue.hasPrefix("20261020-1000-"))
    }

    @Test func explicitStartOverridesCreationDate() async throws {
        let env = try makeEnv()
        let input = try synthesize("wav", in: env.inputs, seconds: 1)
        let m = try await env.importer.importFile(input, startedAt: Samples.start, language: .ja)
        #expect(m.startedAt == Samples.start)
        #expect(m.id.rawValue.hasPrefix("20261024-1400-"))
    }

    @Test func rejectsUnsupportedExtension() async throws {
        let env = try makeEnv()
        let input = env.inputs.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: input)
        await #expect(throws: ImportError.unsupportedFormat("txt")) {
            try await env.importer.importFile(input, language: .ja)
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: env.paths.recordingsDirectory.path)) ?? []).isEmpty)
    }

    @Test func garbageFileIsUnreadable() async throws {
        let env = try makeEnv()
        let input = env.inputs.appending(path: "broken.m4a")
        try Data("this is not audio".utf8).write(to: input)
        do {
            _ = try await env.importer.importFile(input, language: .ja)
            Issue.record("expected a failure")
        } catch let e as ImportError {
            switch e {
            case .unreadable, .noAudioTrack: break
            case .unsupportedFormat: Issue.record("wrong error \(e)")
            }
        }
        #expect(await env.store.all().isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: env.paths.recordingsDirectory.path)) ?? []
        #expect(left.isEmpty)
    }

    @Test func reportsProgressUpToOne() async throws {
        let env = try makeEnv()
        let input = try synthesize("m4a", in: env.inputs)
        let progress = Progress()
        _ = try await env.importer.importFile(input, language: .ja) { progress.add($0) }
        let values = progress.all
        #expect(values.last == 1.0)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values.allSatisfy { (0...1).contains($0) })
    }
}
