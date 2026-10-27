import Testing
import Foundation
@testable import AutoNoteCore

/// The queue fixture `scripts/e2e-check.sh` copies into the data folder before launching the app (E2E 07.4).
@Suite struct E2EFixtureTests {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Fixtures/queue/20261025-0930-c3d4.json")

    @Test func failedJobFixtureDecodes() throws {
        let job = try AutoNoteJSON.decoder().decode(Job.self, from: Data(contentsOf: Self.fixture))
        #expect(job.state == .failed)
        #expect(job.lastError == "final_transcription_failed: TranscriptionError")
    }
}
