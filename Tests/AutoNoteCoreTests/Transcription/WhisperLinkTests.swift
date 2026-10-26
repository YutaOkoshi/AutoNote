import Testing
@testable import AutoNoteCore

@Test func whisperIsLinked() {
    #expect(!WhisperRuntime.systemInfo().isEmpty)
    #expect(WhisperRuntime.languageID("ja") >= 0)
    #expect(WhisperRuntime.languageID("en") >= 0)
}

@Test func machineKindFromSysctl() {
    #expect(MachineKind.from(arm64Flag: 1) == .appleSilicon)
    #expect(MachineKind.from(arm64Flag: 0) == .intel)
    #expect(MachineKind.from(arm64Flag: nil) == .intel)   // Intel では sysctl 自体が失敗する
}

@Test func x86SliceHasAVX2() {
    #if arch(x86_64)
    #expect(WhisperRuntime.systemInfo().contains("AVX2 = 1"))
    #expect(WhisperRuntime.systemInfo().contains("FMA = 1"))
    #endif
}
