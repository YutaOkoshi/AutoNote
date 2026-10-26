import Testing
import Foundation
import CoreAudio
@testable import AutoNoteCore

/// Builds an `AudioBufferList` with one interleaved buffer and hands it to `body`.
private func withABL<R>(interleaved samples: [Float], channels: Int, _ body: (UnsafePointer<AudioBufferList>) throws -> R) rethrows -> R {
    var data = samples
    return try data.withUnsafeMutableBytes { raw in
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<AudioBufferList>.size, alignment: 16)
        defer { ptr.deallocate() }
        let abl = ptr.bindMemory(to: AudioBufferList.self, capacity: 1)
        abl.pointee.mNumberBuffers = 1
        abl.pointee.mBuffers = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
        return try body(UnsafePointer(abl))
    }
}

/// Builds an `AudioBufferList` with one single-channel buffer per channel.
private func withABL<R>(planar channelsData: [[Float]], _ body: (UnsafePointer<AudioBufferList>) throws -> R) rethrows -> R {
    var storage = channelsData.map { UnsafeMutablePointer<Float>.allocate(capacity: max($0.count, 1)) }
    for (i, ch) in channelsData.enumerated() { storage[i].initialize(from: ch, count: ch.count) }
    defer { storage.forEach { $0.deallocate() }; storage.removeAll() }
    let size = MemoryLayout<AudioBufferList>.size + (channelsData.count - 1) * MemoryLayout<AudioBuffer>.stride
    let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    defer { raw.deallocate() }
    let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    abl.pointee.mNumberBuffers = UInt32(channelsData.count)
    withUnsafeMutablePointer(to: &abl.pointee.mBuffers) { first in
        let bufs = UnsafeMutableBufferPointer(start: first, count: channelsData.count)
        for i in 0..<channelsData.count {
            bufs[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(channelsData[i].count * 4), mData: storage[i])
        }
    }
    return try body(UnsafePointer(abl))
}

/// Writes `n` mono frames of value `value`.
@discardableResult
private func writeFrames(_ ring: AudioRingBuffer, _ n: Int, value: Float = 1, hostTime: UInt64 = 0) -> Bool {
    withABL(interleaved: [Float](repeating: value, count: n), channels: 1) {
        ring.write($0, frameCount: n, hostTime: hostTime, sampleTime: 0)
    }
}

@Suite struct AudioRingBufferTests {
    @Test func roundTripsInterleavedFrames() {
        let ring = AudioRingBuffer(channels: 2, capacityFrames: 1024)
        withABL(interleaved: [1, 2, 3, 4, 5, 6], channels: 2) { _ = ring.write($0, frameCount: 3, hostTime: 10, sampleTime: 0) }
        var out: [Float] = []
        #expect(ring.read(into: &out) == .init(hostTime: 10, sampleTime: 0, frameCount: 3))
        #expect(out == [1, 2, 3, 4, 5, 6])
        #expect(ring.read(into: &out) == nil)
    }

    @Test func nonInterleavedIsInterleavedOnWrite() {
        let ring = AudioRingBuffer(channels: 2, capacityFrames: 1024)
        withABL(planar: [[1, 3], [2, 4]]) { _ = ring.write($0, frameCount: 2, hostTime: 0, sampleTime: 0) }
        var out: [Float] = []
        _ = ring.read(into: &out)
        #expect(out == [1, 2, 3, 4])
    }

    @Test func wrapsAround() {
        let ring = AudioRingBuffer(channels: 1, capacityFrames: 8)
        for i in 0..<10 {
            let samples = (0..<5).map { Float(i * 5 + $0) }
            let ok = withABL(interleaved: samples, channels: 1) { ring.write($0, frameCount: 5, hostTime: UInt64(i), sampleTime: Double(i)) }
            #expect(ok)
            var out: [Float] = []
            #expect(ring.read(into: &out) == .init(hostTime: UInt64(i), sampleTime: Double(i), frameCount: 5))
            #expect(out == samples)
        }
        #expect(ring.droppedFrames == 0)
    }

    @Test func overflowDropsWholeCallbackAndCounts() {
        let ring = AudioRingBuffer(channels: 1, capacityFrames: 4)
        #expect(writeFrames(ring, 3, value: 7) == true)
        #expect(writeFrames(ring, 3, value: 9) == false)
        #expect(ring.droppedFrames == 3)
        var out: [Float] = []
        #expect(ring.read(into: &out)?.frameCount == 3)
        #expect(out == [7, 7, 7])
        #expect(ring.read(into: &out) == nil)
        #expect(writeFrames(ring, 3) == true)
    }

    @Test func recordCapacityOverflowDrops() {
        let ring = AudioRingBuffer(channels: 1, capacityFrames: 100, recordCapacity: 2)
        #expect(writeFrames(ring, 1) == true)
        #expect(writeFrames(ring, 1) == true)
        #expect(writeFrames(ring, 1) == false)
        #expect(ring.droppedFrames == 1)
    }

    @Test func concurrentProducerConsumerKeepsOrder() {
        let ring = AudioRingBuffer(channels: 1, capacityFrames: 4096)
        let calls = 20_000, frames = 64
        let producerDone = BoolBox()
        let dropped = IntBox()
        let result = ResultBox()
        let group = DispatchGroup()

        group.enter()
        Thread.detachNewThread {
            var samples = [Float](repeating: 0, count: frames)
            for seq in 1...calls {
                for i in 0..<frames { samples[i] = Float(seq) }
                let ok = withABL(interleaved: samples, channels: 1) {
                    ring.write($0, frameCount: frames, hostTime: UInt64(seq), sampleTime: 0)
                }
                if !ok { dropped.value += frames }
                if seq % 64 == 0 { sched_yield() }
            }
            producerDone.set(true)
            group.leave()
        }
        group.enter()
        Thread.detachNewThread {
            var out: [Float] = []
            var last: UInt64 = 0
            var received = 0
            var good = true
            func drain() {
                while let rec = ring.read(into: &out) {
                    if rec.hostTime <= last || rec.frameCount != frames || out.count != frames { good = false }
                    if !out.allSatisfy({ $0 == Float(rec.hostTime) }) { good = false }
                    last = rec.hostTime
                    received += 1
                }
            }
            while !producerDone.get() { drain() }
            drain()
            result.good = good
            result.received = received
            group.leave()
        }
        group.wait()
        #expect(result.good)
        #expect(result.received * frames + dropped.value == calls * frames)
        #expect(ring.droppedFrames == dropped.value)
        #expect(result.received > 0)
    }
}

private final class IntBox: @unchecked Sendable { var value = 0 }
private final class ResultBox: @unchecked Sendable { var good = false; var received = 0 }
private final class BoolBox: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set(_ x: Bool) { lock.lock(); v = x; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return v }
}
