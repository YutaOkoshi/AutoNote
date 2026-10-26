import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct JobStoreTests {
    private func job(_ id: String, _ created: TimeInterval) -> Job {
        Job(id: id, meeting: MeetingID(rawValue: id), stages: StageName.all, completedStages: [], state: .pending,
            attempts: 0, lastError: nil, notBefore: nil, createdAt: Date(timeIntervalSince1970: created))
    }

    @Test func saveWritesFileNamedByMeetingAndRoundTrips() async throws {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let store = JobStore(paths: paths)
        var j = job("20261024-1400-a1b2", 1_000)
        j.generation = 2
        j.transcriptEngine = "whisper"
        j.summaryFailure = SummaryFailureKind.encode(.rateLimited, message: "hit your limit")
        j.notBefore = Date(timeIntervalSince1970: 2_000)
        j.overwriteApproved = true
        j.completedStages = [StageName.transcribe]
        try await store.save(j)
        let file = paths.root.appending(path: "queue/jobs/20261024-1400-a1b2.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("completed_stages"))
        #expect(text.contains("not_before"))
        #expect(text.contains("overwrite_approved"))
        #expect(try await store.load(j.meeting) == j)
    }

    @Test func allReturnsOldestFirstAndSetsAsideBrokenFiles() async throws {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let store = JobStore(paths: paths)
        try await store.save(job("c", 300)); try await store.save(job("a", 100)); try await store.save(job("b", 200))
        let broken = paths.queueJobsDirectory.appending(path: "x.json")
        try Data("not json".utf8).write(to: broken)
        let jobs = try await store.all()
        #expect(jobs.map(\.id) == ["a", "b", "c"])
        #expect(!FileManager.default.fileExists(atPath: broken.path))
        #expect(FileManager.default.fileExists(atPath: broken.path + ".broken"))
    }

    @Test func saveIsAtomicAndRemoveDeletes() async throws {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let store = JobStore(paths: paths)
        let j = job("a", 1)
        try await store.save(j)
        try await store.save(j)
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.queueJobsDirectory.path)
        #expect(names == ["a.json"])
        #expect(try await store.load(j.meeting) == j)
        try await store.remove(j.meeting)
        #expect(try await store.load(j.meeting) == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.queueJobsDirectory.appending(path: "a.json").path))
        #expect(try await store.load(MeetingID(rawValue: "nope")) == nil)
    }

    @Test func summaryFailureKindRoundTrips() {
        #expect(SummaryFailureKind.encode(.rateLimited, message: "hit your limit") == "rate_limited: hit your limit")
        #expect(SummaryFailureKind.of("not_logged_in: x") == .notLoggedIn)
        #expect(SummaryFailureKind.of(nil) == nil)
        #expect(SummaryFailureKind.of("zzz") == .other)
    }

    @Test func claudeWorkingDirectoryIsUnderRoot() {
        #expect(AppPaths(root: URL(filePath: "/r")).claudeWorkingDirectory.path == "/r/claude-cwd")
    }
}
