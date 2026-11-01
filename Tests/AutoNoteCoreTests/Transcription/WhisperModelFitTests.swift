import Testing
import AutoNoteCore

private let gib: UInt64 = 1 << 30

@Suite struct WhisperModelFitTests {
    private let intel4 = MachineProfile(kind: .intel, physicalCores: 4, physicalMemory: 32 * gib)
    private let m1 = MachineProfile(kind: .appleSilicon, physicalCores: 8, physicalMemory: 8 * gib)

    // この機種（Intel、4 コア、32 GB）で確定版 q5_0 + ライブ whisper q5_0 → 確定版の重さとライブの遅れの両方
    @Test func intelWithLargeFinalAndLargeLiveWhisperWarnsTwice() {
        let w = WhisperModelFit.warnings(profile: intel4, final: .whisper("large-v3-turbo-q5_0"),
                                         live: .whisper("large-v3-turbo-q5_0"))
        #expect(w == [.finalTooSlow(model: "large-v3-turbo-q5_0"), .liveTooSlow(model: "large-v3-turbo-q5_0")])
    }

    @Test func intelLargeTurboFinalWarnsOnSpeedOnly() {
        #expect(WhisperModelFit.warnings(profile: intel4, final: .whisper("large-v3-turbo"), live: .dictation)
            == [.finalTooSlow(model: "large-v3-turbo")])
    }

    // Apple Silicon 8 GB + turbo → メモリの警告だけ
    @Test func appleSilicon8GBWithTurboWarnsOnMemoryOnly() {
        #expect(WhisperModelFit.warnings(profile: m1, final: .whisper("large-v3-turbo"), live: .speech)
            == [.finalLowMemory(model: "large-v3-turbo")])
    }

    @Test func appleSiliconNeverWarnsOnSpeed() {
        let big = MachineProfile(kind: .appleSilicon, physicalCores: 8, physicalMemory: 16 * gib)
        #expect(WhisperModelFit.warnings(profile: big, final: .whisper("large-v3-turbo"), live: .whisper("large-v3-turbo")).isEmpty)
        #expect(WhisperModelFit.warnings(profile: m1, final: .whisper("large-v3-turbo-q5_0"), live: .whisper("large-v3-turbo-q5_0")).isEmpty)
    }

    // Intel + small + live dictation → 警告なし
    @Test func intelSmallWithDictationIsQuiet() {
        #expect(WhisperModelFit.warnings(profile: intel4, final: .whisper("small"), live: .dictation).isEmpty)
    }

    @Test func intelLiveWhisperSmallOrBaseIsQuiet() {
        #expect(WhisperModelFit.warnings(profile: intel4, final: .whisper("base"), live: .whisper("small")).isEmpty)
        #expect(WhisperModelFit.warnings(profile: intel4, final: .whisper("base"), live: .whisper("base")).isEmpty)
    }

    @Test func intel8GBWithTurboWarnsOnSpeedAndMemory() {
        let small = MachineProfile(kind: .intel, physicalCores: 4, physicalMemory: 8 * gib)
        #expect(WhisperModelFit.warnings(profile: small, final: .whisper("large-v3-turbo"), live: nil)
            == [.finalTooSlow(model: "large-v3-turbo"), .finalLowMemory(model: "large-v3-turbo")])
    }

    @Test func noEngineOrAppleEngineIsQuiet() {
        #expect(WhisperModelFit.warnings(profile: intel4, final: nil, live: nil).isEmpty)
        #expect(WhisperModelFit.warnings(profile: intel4, final: EngineChoice(kind: .whisper), live: .speech).isEmpty)
    }

    // 自動のスレッド数 = 物理コア数 − 1、上限 4、下限 1
    @Test func automaticBatchThreadsLeaveOneCore() {
        #expect(MachineProfile.automaticBatchThreads(physicalCores: 4) == 3)
        #expect(MachineProfile.automaticBatchThreads(physicalCores: 8) == 4)
        #expect(MachineProfile.automaticBatchThreads(physicalCores: 2) == 1)
        #expect(MachineProfile.automaticBatchThreads(physicalCores: 1) == 1)
        #expect(MachineProfile.automaticBatchThreads(physicalCores: 0) == 1)
    }

    @Test func batchThreadsFollowTheSettingOrAutomatic() {
        #expect(intel4.batchThreads(setting: nil) == 3)
        #expect(m1.batchThreads(setting: nil) == 4)
        #expect(intel4.batchThreads(setting: 2) == 2)
        #expect(intel4.batchThreads(setting: 4) == 4)
        #expect(intel4.batchThreads(setting: 0) == 1)
        #expect(intel4.batchThreads(setting: 99) == 8)
    }

    @Test func threadChoicesRunToThePhysicalCoreCount() {
        #expect(intel4.threadChoices == [1, 2, 3, 4])
        #expect(MachineProfile(kind: .intel, physicalCores: 12, physicalMemory: gib).threadChoices == Array(1...8))
    }

    @Test func currentProfileIsPlausible() {
        let p = MachineProfile.current()
        #expect(p.kind == MachineKind.current())
        #expect(p.physicalCores >= 1)
        #expect(p.physicalMemory > 0)
    }
}
