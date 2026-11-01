import Foundation
import Testing
import AutoNoteTestSupport
@testable import AutoNoteCore

@Suite struct PromptMigrationTests {
    private func store() throws -> (PortableConfigStore, URL) {
        let vault = try TemporaryDirectory.make()
        let paths = AppPaths(root: try TemporaryDirectory.make())
        return (PortableConfigStore(paths: paths, outputFolder: vault), vault)
    }

    private func vaultPrompt(_ vault: URL) throws -> String {
        try String(contentsOf: vault.appending(path: "_autonote/prompt.md"), encoding: .utf8)
    }

    @Test func legacyHashMatchesLegacyText() {
        #expect(PromptMigration.legacyDefaultSHA256s.contains(PromptMigration.sha256(DefaultPrompt.legacyInstructionsV1)))
        #expect(DefaultPrompt.legacyInstructionsV1.contains("ちょうど 3 件"))
        #expect(DefaultPrompt.legacyInstructionsV1 != DefaultPrompt.instructions)
    }

    @Test func classifiesPromptText() {
        #expect(PromptMigration.state(of: nil) == .empty)
        #expect(PromptMigration.state(of: " \n") == .empty)
        #expect(PromptMigration.state(of: DefaultPrompt.instructions) == .currentDefault)
        #expect(PromptMigration.state(of: DefaultPrompt.instructions + "\n") == .currentDefault)
        #expect(PromptMigration.state(of: DefaultPrompt.legacyInstructionsV1) == .legacyDefault)
        #expect(PromptMigration.state(of: DefaultPrompt.legacyInstructionsV1 + "\n") == .legacyDefault)
        // One character changed is an edit.
        let edited = DefaultPrompt.legacyInstructionsV1.replacingOccurrences(of: "日本語で書く。", with: "日本語で書く")
        #expect(PromptMigration.state(of: edited) == .customized)
        #expect(PromptMigration.needsReview(edited))
        #expect(!PromptMigration.needsReview(DefaultPrompt.legacyInstructionsV1))
        #expect(!PromptMigration.needsReview(DefaultPrompt.instructions))
        #expect(!PromptMigration.needsReview(nil))
        // An edited prompt that already talks about the v2 keys was written for v2.
        #expect(!PromptMigration.needsReview("自分の指示。risks も書く。"))
    }

    @Test func untouchedLegacyDefaultIsReplaced() async throws {
        let (store, vault) = try store()
        try await store.write(.prompt, Data(DefaultPrompt.legacyInstructionsV1.utf8))
        #expect(try await PromptMigration.effectiveInstructions(store) == DefaultPrompt.instructions)
        #expect(try vaultPrompt(vault) == DefaultPrompt.instructions)
    }

    @Test func editedPromptIsKept() async throws {
        let (store, vault) = try store()
        let edited = DefaultPrompt.legacyInstructionsV1 + "\n- 敬体で書く。"
        try await store.write(.prompt, Data(edited.utf8))
        #expect(try await PromptMigration.effectiveInstructions(store) == edited)
        #expect(try vaultPrompt(vault) == edited)
    }

    @Test func missingOrEmptyFileUsesDefaultWithoutWriting() async throws {
        let (store, vault) = try store()
        #expect(try await PromptMigration.effectiveInstructions(store) == DefaultPrompt.instructions)
        #expect(!FileManager.default.fileExists(atPath: vault.appending(path: "_autonote/prompt.md").path))
        try await store.write(.prompt, Data())
        #expect(try await PromptMigration.effectiveInstructions(store) == DefaultPrompt.instructions)
        #expect(try vaultPrompt(vault) == "")
    }

    @Test func newInstallDefaultIsCurrent() {
        #expect(PortableDefaults.standard[.prompt] == Data(DefaultPrompt.instructions.utf8))
    }
}
