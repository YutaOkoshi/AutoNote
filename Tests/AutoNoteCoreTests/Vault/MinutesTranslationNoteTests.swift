import AutoNoteTestSupport
import Foundation
import Testing
@testable import AutoNoteCore

/// The note's translated minutes (spec 2026-11-19 表示: 訳があるとき末尾に訳文の節を足す).
@Suite struct MinutesTranslationNoteTests {
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func translation(_ pairs: [(String, String)]) -> SummaryTranslationDocument {
        SummaryTranslationDocument(model: "2b", modelRevision: "r", target: .auto, updatedAt: Date(timeIntervalSince1970: 0),
                                   entries: pairs.map {
                                       SummaryTranslatedText(sourceHash: TranslationKey.textHash($0.0), sourceLanguage: .ja,
                                                             targetLanguage: .en, text: $0.1)
                                   })
    }

    private func document(_ minutes: MinutesOutput?, _ t: SummaryTranslationDocument?) -> MeetingDocument {
        MeetingDocument(manifest: Samples.manifest,
                        transcript: Transcript(utterances: [u(5, .me, "はじめます"), u(754, .other, "来週出します")],
                                               engine: "whisper.cpp", language: .ja),
                        minutes: minutes, frontmatter: .init(text: FrontmatterTemplate.defaultText), appVersion: "0.7.0",
                        timeZone: Self.tokyo, minutesTranslation: t)
    }

    private var sampleTranslation: SummaryTranslationDocument {
        let m = Samples.minutes
        return translation([(m.title, "Project sync"), (m.decisions[0].text, "Release next week"),
                            (m.summary[0], "Summary in English")])
    }

    @Test func theTranslatedMinutesComeLastWithTheirLinks() throws {
        let plain = document(Samples.minutes, nil).render()
        let s = document(Samples.minutes, sampleTranslation).render()
        let heading = "## " + MeetingDocument.translationHeading(.en)
        #expect(heading == "## 議事録の訳文（英語）")
        // Everything before is the same note; the section is appended at the end, after the transcript.
        let head = String(plain.dropLast())
        #expect(s.hasPrefix(head))
        let section = String(s.dropFirst(head.count))
        #expect(section.hasPrefix("\n\n" + heading + "\n"))
        #expect(s.hasSuffix("\n") && !s.hasSuffix("\n\n"))
        #expect(section.contains("**Project sync**"))
        #expect(section.contains("- Release next week [["))
        #expect(section.contains("Summary in English"))
        // The original's headings stay the note's own (the index reads the first 「## 要約」).
        #expect(section.contains("\n### 要約\n") && !section.contains("\n## 要約\n"))
        // Texts without a translation stay as they are.
        #expect(section.contains(Samples.minutes.agenda[0].title))
    }

    @Test func noSectionWithoutAUsableTranslation() {
        let plain = document(Samples.minutes, nil).render()
        #expect(document(Samples.minutes, translation([])).render() == plain)
        // A translation of other texts (the minutes were redone) is not used.
        #expect(document(Samples.minutes, translation([("前の決定", "Old decision")])).render() == plain)
        // No minutes: nothing to translate.
        #expect(document(nil, sampleTranslation).render() == document(nil, nil).render())
    }

    @Test func theQueueWritesTheTranslationIntoTheNote() async throws {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let manifests = ManifestStore(paths: paths)
        var manifest = Samples.manifest
        manifest.status = .generating
        try await manifests.save(manifest)
        let id = manifest.id
        let final = Transcript(utterances: [u(1, .me, "はじめます")], engine: "whisper.cpp", language: .ja)
        try FileManager.default.createDirectory(at: paths.transcriptsDirectory(id), withIntermediateDirectories: true)
        try AutoNoteJSON.encoder().encode(final).write(to: paths.transcriptFile(id, .final))
        try AutoNoteJSON.encoder().encode(Samples.minutes).write(to: paths.minutesFile(id))
        try TranslationStore(paths: paths).saveSummary(sampleTranslation, .minutes, for: id)
        let output = try TemporaryDirectory.make()
        var settings = Settings()
        settings.outputFolder = output.path
        let services = SharedVaultServices()
        let context = StageContext(paths: paths, settings: settings, manifests: manifests,
                                   now: { Date(timeIntervalSince1970: 1_800_000_000) }, reportProgress: { _ in })
        var job = Job(id: id.rawValue, meeting: id, stages: StageName.all,
                      completedStages: [StageName.transcribe, StageName.summarize], state: .running, attempts: 0,
                      lastError: nil, notBefore: nil, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        try await WriteVaultStage(timeZone: Self.tokyo, services: services).run(&job, context: context)
        let note = output.appending(path: "2026/2026-10-24_1400_プロジェクト定例.md")
        #expect(try String(contentsOf: note, encoding: .utf8).contains("## 議事録の訳文（英語）"))

        // A translation finished later rewrites the untouched note…
        let newer = translation([(Samples.minutes.decisions[0].text, "Ship next week")])
        try TranslationStore(paths: paths).saveSummary(newer, .minutes, for: id)
        #expect(await WriteVaultStage.rewriteForTranslation(id, paths: paths, settings: settings, manifests: manifests,
                                                            services: services, timeZone: Self.tokyo) == .rewritten)
        #expect(try String(contentsOf: note, encoding: .utf8).contains("- Ship next week"))
        // …but never one edited outside (the writer's rule), and never the minutes or the manifest's status.
        try Data((try String(contentsOf: note, encoding: .utf8) + "\n自分のメモ\n").utf8).write(to: note)
        #expect(await WriteVaultStage.rewriteForTranslation(id, paths: paths, settings: settings, manifests: manifests,
                                                            services: services, timeZone: Self.tokyo) == .leftAlone)
        #expect(try String(contentsOf: note, encoding: .utf8).contains("自分のメモ"))
        #expect(try await manifests.load(id).status == .minutesGenerated)
    }

    @Test func noRewriteWhileTheQueueIsStillMakingTheNote() async throws {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let manifests = ManifestStore(paths: paths)
        var manifest = Samples.manifest
        manifest.status = .generating
        try await manifests.save(manifest)
        var settings = Settings()
        settings.outputFolder = try TemporaryDirectory.make().path
        #expect(await WriteVaultStage.rewriteForTranslation(manifest.id, paths: paths, settings: settings,
                                                            manifests: manifests) == .leftAlone)
    }
}
