import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import AudioDecode

private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AudioDecodeTests
        .deletingLastPathComponent()  // Tests
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

@Test func decodesWavToFloat32() async throws {
    let audio = try await AudioFileDecoder.decode(url: fixture("sine.wav"))
    #expect(audio.channels == 2)
    #expect(audio.sampleRate == 44100)
    // ~0.4 seconds of raw PCM: no codec priming, so this should be exact,
    // but leave a little slop for container rounding.
    #expect(abs(audio.frameCount - 17640) < 50)
}

@Test(arguments: [
    ("sine.mp3", 44100.0), ("sine.flac", 44100.0), ("sine.m4a", 44100.0),
    ("sine.ogg", 44100.0), ("sine.opus", 48000.0)
])
func decodesEveryNativeFormat(name: String, expectedRate: Double) async throws {
    let audio = try await AudioFileDecoder.decode(url: fixture(name))
    #expect(audio.channels == 2)
    #expect(audio.sampleRate == expectedRate)
    #expect(audio.frameCount > Int64(expectedRate))  // more than 1 second

    // A 440 Hz sine must have real signal in it.
    let ch = audio.channel(0)
    var peak: Float = 0
    for i in 0..<Int(audio.frameCount) { peak = max(peak, abs(ch[i])) }
    #expect(peak > 0.3)
    #expect(peak <= 1.01)
}

@Test func preserves24BitResolution() async throws {
    let audio = try await AudioFileDecoder.decode(url: fixture("sine24.flac"))
    let ch = audio.channel(0)
    // If the decoder silently produced Int16, every sample would be an exact
    // multiple of 1/32768. Assert that some sample is not.
    let step: Float = 1.0 / 32768.0
    var foundSubQuantumValue = false
    for i in 0..<Int(audio.frameCount) {
        let quotient = ch[i] / step
        if abs(quotient - quotient.rounded()) > 0.01 { foundSubQuantumValue = true; break }
    }
    #expect(foundSubQuantumValue, "decoder appears to have quantised a 24-bit source to 16 bits")
}

@Test func missingFileThrowsUnreadable() async {
    await #expect(throws: DecodeError.self) {
        _ = try await AudioFileDecoder.decode(url: URL(fileURLWithPath: "/nope/missing.wav"))
    }
}

/// A `@Sendable` progress closure cannot capture a local `var`, so collect through
/// a locked reference type.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func record(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
    var snapshot: [Double] { lock.lock(); defer { lock.unlock() }; return values }
}

@Test func reportsMonotonicProgress() async throws {
    let log = ProgressLog()
    _ = try await AudioFileDecoder.decode(url: fixture("sine.flac")) { log.record($0) }
    let samples = log.snapshot
    #expect(!samples.isEmpty)
    #expect(samples == samples.sorted())
    let last = try #require(samples.last)
    #expect(last >= 0.99)
}

// MARK: - Defect regression: capacity overflow must grow, never truncate.

@Test func decodeDoesNotTruncateWhenDurationEstimateIsExceeded() async throws {
    // sine.flac is ~2s (~88200 frames at 44.1kHz). Force the initial capacity
    // estimate absurdly low (far below even one AVAssetReader sample buffer)
    // to prove the decoder grows its storage instead of silently stopping
    // partway through and returning a truncated buffer.
    let full = try await AudioFileDecoder.decode(url: fixture("sine.flac"))
    let starved = try await AudioFileDecoder.decode(
        url: fixture("sine.flac"), progress: nil, initialCapacityHint: 8)
    #expect(starved.frameCount == full.frameCount)
    #expect(starved.storage.capacityFrames >= Int(starved.frameCount))

    // The actual audio content must match too, not just the frame count.
    let a = full.channel(0)
    let b = starved.channel(0)
    for i in stride(from: 0, to: Int(full.frameCount), by: 997) {
        #expect(a[i] == b[i])
    }
}

@Test func audioStorageGrowPreservesExistingSamplesAndUpdatesCapacity() {
    let storage = AudioStorage(channels: 2, capacityFrames: 4)
    storage.pointer(0)[0] = 1
    storage.pointer(0)[1] = 2
    storage.pointer(0)[2] = 3
    storage.pointer(0)[3] = 4
    storage.pointer(1)[0] = 10
    storage.pointer(1)[3] = 40

    storage.grow(toAtLeast: 100, preserving: 4)

    #expect(storage.capacityFrames >= 100)
    #expect(storage.pointer(0)[0] == 1)
    #expect(storage.pointer(0)[1] == 2)
    #expect(storage.pointer(0)[2] == 3)
    #expect(storage.pointer(0)[3] == 4)
    #expect(storage.pointer(1)[0] == 10)
    #expect(storage.pointer(1)[3] == 40)

    // Newly grown region must still be valid, zero-initialised memory (not
    // garbage from the allocator) so nothing downstream reads uninitialised
    // floats.
    #expect(storage.pointer(0)[99] == 0)

    // Growing to a size already satisfied is a no-op (capacity unchanged).
    let capacityBeforeNoOpGrow = storage.capacityFrames
    storage.grow(toAtLeast: 1, preserving: 4)
    #expect(storage.capacityFrames == capacityBeforeNoOpGrow)
}

// MARK: - Defect regression: non-contiguous CMBlockBuffer must be read in full.

private func makeBlockBuffer(bytes: [UInt8]) throws -> CMBlockBuffer {
    var maybeBuffer: CMBlockBuffer?
    let createStatus = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: bytes.count,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: bytes.count,
        flags: 0,
        blockBufferOut: &maybeBuffer)
    #expect(createStatus == noErr)
    let buffer = try #require(maybeBuffer)

    let replaceStatus = bytes.withUnsafeBytes { raw -> OSStatus in
        guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
        return CMBlockBufferReplaceDataBytes(
            with: base, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: bytes.count)
    }
    #expect(replaceStatus == noErr)
    return buffer
}

@Test func copyBytesReadsFullyAcrossNonContiguousSegments() throws {
    let segmentA: [UInt8] = [1, 2, 3, 4]
    let segmentB: [UInt8] = [5, 6, 7, 8, 9, 10]
    let bufferA = try makeBlockBuffer(bytes: segmentA)
    let bufferB = try makeBlockBuffer(bytes: segmentB)

    var structured: CMBlockBuffer?
    let emptyStatus = CMBlockBufferCreateEmpty(
        allocator: kCFAllocatorDefault, capacity: 2, flags: 0, blockBufferOut: &structured)
    #expect(emptyStatus == noErr)
    let parent = try #require(structured)

    #expect(
        CMBlockBufferAppendBufferReference(
            parent, targetBBuf: bufferA, offsetToData: 0, dataLength: segmentA.count, flags: 0)
            == noErr)
    #expect(
        CMBlockBufferAppendBufferReference(
            parent, targetBBuf: bufferB, offsetToData: 0, dataLength: segmentB.count, flags: 0)
            == noErr)

    let totalLength = CMBlockBufferGetDataLength(parent)
    #expect(totalLength == segmentA.count + segmentB.count)

    // Confirm this buffer really is non-contiguous end to end, i.e. that the
    // scenario the defect describes is actually being exercised here and not
    // vacuously true.
    #expect(!CMBlockBufferIsRangeContiguous(parent, atOffset: 0, length: totalLength))

    // The naive approach (`CMBlockBufferGetDataPointer` + `totalLengthOut`)
    // would read `totalLength` bytes starting from a pointer only guaranteed
    // valid for `lengthAtOffsetOut` bytes. Demonstrate that gap exists here.
    var lengthAtOffset = 0
    var totalLengthOut = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    let pointerStatus = CMBlockBufferGetDataPointer(
        parent, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLengthOut,
        dataPointerOut: &dataPointer)
    #expect(pointerStatus == noErr)
    #expect(totalLengthOut == totalLength)
    #expect(
        lengthAtOffset < totalLengthOut,
        "expected the naive read to be short of the full buffer on this non-contiguous case"
    )

    // The robust helper must recover every byte from both segments.
    let recovered = try AudioFileDecoder.copyBytes(from: parent)
    #expect(
        recovered == segmentA.map { Int8(bitPattern: $0) } + segmentB.map { Int8(bitPattern: $0) })
}

// MARK: - Real-media sanity check (optional)

/// Not a fixture: points at real, copyrighted 24-bit/44.1 FLAC material that is
/// never committed to the repo. Skips cleanly (via `.enabled(if:)`, not a failure)
/// when the environment variable is unset, which is the default everywhere except
/// a developer's machine that has opted in.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ARTSCRIBE_TEST_MEDIA_DIR"] != nil))
func decodesRealWorldTrackWithoutTruncation() async throws {
    let dirPath = try #require(ProcessInfo.processInfo.environment["ARTSCRIBE_TEST_MEDIA_DIR"])
    let dir = URL(fileURLWithPath: dirPath)
    let flacFiles =
        try FileManager.default
        .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "flac" }
        .sorted { $0.path < $1.path }
    try #require(!flacFiles.isEmpty, "no .flac files found under \(dirPath)")

    let track = flacFiles[0]
    let asset = AVURLAsset(url: track)
    let containerDuration = try await asset.load(.duration)

    let audio = try await AudioFileDecoder.decode(url: track)
    #expect(audio.channels == 2)
    #expect(audio.sampleRate == 44100)

    // The decoded length must land within a second of the container-reported
    // duration -- i.e. the capacity-growth path held on real, multi-hundred-MB
    // decoded output and did not truncate.
    let expectedFrames = containerDuration.seconds * audio.sampleRate
    #expect(abs(Double(audio.frameCount) - expectedFrames) < audio.sampleRate)

    // A real 24-bit source: same regression as `preserves24BitResolution`.
    let ch = audio.channel(0)
    let step: Float = 1.0 / 32768.0
    var foundSubQuantumValue = false
    for i in 0..<Int(audio.frameCount) {
        let quotient = ch[i] / step
        if abs(quotient - quotient.rounded()) > 0.01 { foundSubQuantumValue = true; break }
    }
    #expect(foundSubQuantumValue)
}
