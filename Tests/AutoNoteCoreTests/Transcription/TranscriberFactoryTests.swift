import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Testing

@Suite struct TranscriberFactoryTests {
    private func factory() throws -> TranscriberFactory {
        TranscriberFactory(models: ModelManager(directory: try TemporaryDirectory.make(), catalog: []), machine: .intel)
    }

    @Test func batchRejectsAppleEngines() async throws {
        let f = try factory()
        await #expect(throws: TranscriptionError.engineUnavailable("dictation cannot run as a batch engine")) {
            _ = try await f.makeBatch(.dictation, gate: BatchGate())
        }
        await #expect(throws: TranscriptionError.engineUnavailable("speech cannot run as a batch engine")) {
            _ = try await f.makeBatch(.speech, gate: BatchGate())
        }
    }

    @Test func missingModelIsReported() async throws {
        let f = try factory()
        await #expect(throws: TranscriptionError.modelMissing("small")) {
            _ = try await f.makeBatch(.whisper("small"), gate: BatchGate())
        }
        await #expect(throws: TranscriptionError.modelMissing("small")) {
            _ = try await f.makeLive(.whisper("small"))
        }
    }

    @Test func liveDictationIsConstructible() async throws {
        let f = try factory()
        let live = try await f.makeLive(.dictation)
        #expect(live is DictationLiveTranscriber)
        #expect(try await f.makeLive(.speech) is SpeechLiveTranscriber)
    }
}
