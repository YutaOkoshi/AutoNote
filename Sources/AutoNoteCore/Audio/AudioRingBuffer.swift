import Foundation
import CoreAudio
import Synchronization

/// Fixed-size single-producer / single-consumer ring of interleaved Float frames.
///
/// `write` is meant to be called from an audio callback: it does not lock, allocate, log or do I/O.
/// All storage is allocated in `init`. Exactly one thread may call `write` and exactly one may call `read`.
/// One `write` call produces one record; one `read` call consumes one record.
public final class AudioRingBuffer: @unchecked Sendable {
    public struct Record: Sendable, Equatable {
        public var hostTime: UInt64
        public var sampleTime: Double
        public var frameCount: Int

        public init(hostTime: UInt64, sampleTime: Double, frameCount: Int) {
            self.hostTime = hostTime
            self.sampleTime = sampleTime
            self.frameCount = frameCount
        }
    }

    public let channels: Int

    private let capacityFrames: Int
    private let recordCapacity: Int
    private let samples: UnsafeMutablePointer<Float>
    private let records: UnsafeMutablePointer<Record>
    /// Byte offset of `AudioBufferList.mBuffers`, computed here so `write` never builds a key path (it allocates in
    /// unoptimized builds).
    private let buffersOffset: Int

    // Monotonic counters (never wrapped); the slot is `counter % capacity`.
    private let writeFrameIndex = Atomic<Int>(0)
    private let readFrameIndex = Atomic<Int>(0)
    private let writeRecordIndex = Atomic<Int>(0)
    private let readRecordIndex = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)

    public init(channels: Int, capacityFrames: Int, recordCapacity: Int = 4096) {
        precondition(channels > 0 && capacityFrames > 0 && recordCapacity > 0)
        self.channels = channels
        self.capacityFrames = capacityFrames
        self.recordCapacity = recordCapacity
        buffersOffset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        samples = .allocate(capacity: capacityFrames * channels)
        samples.initialize(repeating: 0, count: capacityFrames * channels)
        records = .allocate(capacity: recordCapacity)
        records.initialize(repeating: Record(hostTime: 0, sampleTime: 0, frameCount: 0), count: recordCapacity)
    }

    deinit {
        samples.deallocate()
        records.deallocate()
    }

    public var droppedFrames: Int { dropped.load(ordering: .relaxed) }

    /// Producer side. Returns false (and counts `frameCount` as dropped) when the callback cannot be stored whole.
    @discardableResult
    public func write(_ abl: UnsafePointer<AudioBufferList>, frameCount: Int, hostTime: UInt64, sampleTime: Double) -> Bool {
        guard frameCount > 0 else { return true }
        let channels = self.channels
        let bufferCount = Int(abl.pointee.mNumberBuffers)
        let first = UnsafeRawPointer(abl).advanced(by: buffersOffset)
            .assumingMemoryBound(to: AudioBuffer.self)

        // Layout check: one interleaved buffer, or one single-channel buffer per channel.
        let interleaved = bufferCount == 1 && Int(first[0].mNumberChannels) == channels
        let planar = !interleaved && bufferCount == channels
        var valid = interleaved || planar
        if valid {
            if interleaved {
                valid = first[0].mData != nil && Int(first[0].mDataByteSize) >= frameCount * channels * MemoryLayout<Float>.size
            } else {
                for c in 0..<bufferCount where first[c].mData == nil
                    || Int(first[c].mNumberChannels) != 1
                    || Int(first[c].mDataByteSize) < frameCount * MemoryLayout<Float>.size {
                    valid = false
                }
            }
        }

        let wFrames = writeFrameIndex.load(ordering: .relaxed)
        let rFrames = readFrameIndex.load(ordering: .acquiring)
        let wRecs = writeRecordIndex.load(ordering: .relaxed)
        let rRecs = readRecordIndex.load(ordering: .acquiring)
        guard valid,
              capacityFrames - (wFrames - rFrames) >= frameCount,
              recordCapacity - (wRecs - rRecs) >= 1 else {
            dropped.add(frameCount, ordering: .relaxed)
            return false
        }

        var slot = wFrames % capacityFrames
        if interleaved {
            let src = first[0].mData!.assumingMemoryBound(to: Float.self)
            let head = min(frameCount, capacityFrames - slot)
            (samples + slot * channels).update(from: src, count: head * channels)
            if head < frameCount {
                samples.update(from: src + head * channels, count: (frameCount - head) * channels)
            }
        } else {
            for f in 0..<frameCount {
                let dst = samples + slot * channels
                for c in 0..<channels {
                    dst[c] = first[c].mData!.assumingMemoryBound(to: Float.self)[f]
                }
                slot += 1
                if slot == capacityFrames { slot = 0 }
            }
        }
        records[wRecs % recordCapacity] = Record(hostTime: hostTime, sampleTime: sampleTime, frameCount: frameCount)
        writeFrameIndex.store(wFrames + frameCount, ordering: .releasing)
        writeRecordIndex.store(wRecs + 1, ordering: .releasing)
        return true
    }

    /// Consumer side. Takes the oldest record; `buffer` is resized to `frameCount * channels` interleaved samples.
    public func read(into buffer: inout [Float]) -> Record? {
        let rRecs = readRecordIndex.load(ordering: .relaxed)
        let wRecs = writeRecordIndex.load(ordering: .acquiring)
        guard rRecs != wRecs else { return nil }
        let record = records[rRecs % recordCapacity]
        let rFrames = readFrameIndex.load(ordering: .relaxed)
        let count = record.frameCount * channels
        if buffer.count != count {
            buffer = [Float](repeating: 0, count: count)
        }
        let slot = rFrames % capacityFrames
        let head = min(record.frameCount, capacityFrames - slot)
        buffer.withUnsafeMutableBufferPointer { dst in
            dst.baseAddress!.update(from: samples + slot * channels, count: head * channels)
            if head < record.frameCount {
                (dst.baseAddress! + head * channels).update(from: samples, count: (record.frameCount - head) * channels)
            }
        }
        readFrameIndex.store(rFrames + record.frameCount, ordering: .releasing)
        readRecordIndex.store(rRecs + 1, ordering: .releasing)
        return record
    }
}
