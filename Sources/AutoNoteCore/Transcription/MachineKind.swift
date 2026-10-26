import Darwin

/// 実行中の Mac の種類。機種依存の分岐は `#if arch` ではなくこの実行時判定で行う。
public enum MachineKind: String, Codable, Sendable {
    case intel
    case appleSilicon

    /// `sysctlbyname("hw.optional.arm64")` で判定する。Intel ではこのキー自体が無く失敗する。
    public static func current() -> MachineKind {
        var flag: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = sysctlbyname("hw.optional.arm64", &flag, &size, nil, 0)
        return from(arm64Flag: status == 0 ? flag : nil)
    }

    /// `hw.optional.arm64` の値（取得できなければ nil）から機種を決める。1 のときだけ Apple Silicon。
    public static func from(arm64Flag: Int32?) -> MachineKind {
        arm64Flag == 1 ? .appleSilicon : .intel
    }
}
