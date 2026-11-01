import Darwin
import Foundation

/// What the whisper sizing decisions need to know about this Mac: its kind (Metal or not), physical cores and memory.
/// Read once per caller with `current()`; tests pass the values directly.
public struct MachineProfile: Equatable, Sendable {
    public var kind: MachineKind
    public var physicalCores: Int
    public var physicalMemory: UInt64

    public init(kind: MachineKind, physicalCores: Int, physicalMemory: UInt64) {
        self.kind = kind
        self.physicalCores = physicalCores
        self.physicalMemory = physicalMemory
    }

    /// `MachineKind.current()`, `sysctl hw.physicalcpu` (falls back to half the logical cores) and
    /// `ProcessInfo.physicalMemory`.
    public static func current() -> MachineProfile {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = sysctlbyname("hw.physicalcpu", &cores, &size, nil, 0)
        let physical = status == 0 && cores > 0 ? Int(cores) : max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
        return MachineProfile(kind: .current(), physicalCores: physical,
                              physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    /// The range `Settings.finalThreads` is clamped to.
    public static let batchThreadRange: ClosedRange<Int> = 1...8

    /// Automatic batch threads: one physical core is left for other work, at most 4, at least 1
    /// (4 cores → 3, 8 cores → 4).
    public static func automaticBatchThreads(physicalCores: Int) -> Int {
        min(4, max(1, physicalCores - 1))
    }

    /// The `final_threads` setting clamped to `batchThreadRange`, or the automatic value when it is nil.
    public func batchThreads(setting: Int?) -> Int {
        guard let setting else { return Self.automaticBatchThreads(physicalCores: physicalCores) }
        return min(max(setting, Self.batchThreadRange.lowerBound), Self.batchThreadRange.upperBound)
    }

    /// The explicit values the settings screen offers: 1 up to the physical core count (inside `batchThreadRange`).
    public var threadChoices: [Int] {
        Array(Self.batchThreadRange.lowerBound...min(Self.batchThreadRange.upperBound, max(1, physicalCores)))
    }
}
