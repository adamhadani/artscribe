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

/// What this platform decodes without a bundled codec.
///
/// **The format list is a macOS fact, not an Apple-platform one.** Measured on an
/// iPad simulator, 2026-07-30: every entry below passes on both, and `sine.ogg`
/// passes only on macOS — on iOS it fails `.unreadable("Operation Stopped")`.
///
/// Ogg is therefore moved into `oggVorbisDoesNotDecodeOnThisPlatform` rather than
/// dropped. Deleting the case would have made this suite green on a simulator
/// while hiding a difference a user meets as "this file just will not open", and
/// the *asserted* version has the property that matters: if iOS ever gains Ogg
/// support, a test fails and says so.
private let nativeFormats: [(String, Double)] = {
    var formats: [(String, Double)] = [
        ("sine.mp3", 44100.0), ("sine.flac", 44100.0), ("sine.m4a", 44100.0),
        ("sine.opus", 48000.0)
    ]
    #if os(macOS)
    formats.append(("sine.ogg", 44100.0))
    #endif
    return formats
}()

@Test(arguments: nativeFormats)
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

/// Counts sign changes between consecutive samples -- a cheap, FFT-free proxy
/// for a sine wave's frequency (a tone at `f` Hz crosses zero `2 * f * duration`
/// times, since each cycle crosses twice).
private func zeroCrossings(_ samples: UnsafePointer<Float>, count: Int) -> Int {
    guard count > 1 else { return 0 }
    var crossings = 0
    for i in 1..<count where samples[i - 1] * samples[i] < 0 {
        crossings += 1
    }
    return crossings
}

@Test func decodePreservesChannelIdentityAndOrder() async throws {
    // Every other fixture here is a mono sine identically upmixed to both
    // channels -- L and R are byte-for-byte identical, so nothing above can
    // detect a channel swap or a misaligned `deinterleave` index (`floats[i *
    // channels + c]`). `sine_stereo_distinct.flac` carries 440 Hz on channel 0
    // and 660 Hz on channel 1: a swap or misalignment fails this test.
    let audio = try await AudioFileDecoder.decode(url: fixture("sine_stereo_distinct.flac"))
    #expect(audio.channels == 2)
    let n = Int(audio.frameCount)
    let ch0 = audio.channel(0)
    let ch1 = audio.channel(1)

    var identical = true
    for i in 0..<n where ch0[i] != ch1[i] {
        identical = false
        break
    }
    #expect(
        !identical,
        "left and right channel content is byte-identical -- fixture or decode path is not stereo"
    )

    let duration = Double(n) / audio.sampleRate
    let crossings0 = zeroCrossings(ch0, count: n)
    let crossings1 = zeroCrossings(ch1, count: n)
    let expected440 = 2 * 440.0 * duration
    let expected660 = 2 * 660.0 * duration

    // Channel 0 must carry ~440 Hz and channel 1 ~660 Hz, in that order: a
    // channel swap would fail both of these simultaneously (each count would
    // land near the *other* channel's expectation instead).
    #expect(abs(Double(crossings0) - expected440) < expected440 * 0.15)
    #expect(abs(Double(crossings1) - expected660) < expected660 * 0.15)
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

    // The robust helper must recover every byte from both segments. (Reads
    // into a reused scratch allocation rather than returning a fresh array --
    // see `AudioFileDecoder.SampleScratch` -- but the correctness contract
    // being exercised here is unchanged: every byte from every segment.)
    let scratch = AudioFileDecoder.SampleScratch()
    let recoveredLength = try AudioFileDecoder.copyBytes(from: parent, into: scratch)
    #expect(recoveredLength == totalLength)
    let recovered = (0..<recoveredLength).map {
        scratch.buffer.load(fromByteOffset: $0, as: Int8.self)
    }
    #expect(
        recovered == segmentA.map { Int8(bitPattern: $0) } + segmentB.map { Int8(bitPattern: $0) })
}

@Test func copyBytesReturnsZeroForEmptyBlockBuffer() throws {
    // The benign half of the defect-2 fix's sibling decision (finding 2 from
    // review round 2): a genuinely zero-length `CMBlockBuffer` carries no
    // payload to lose, so `copyBytes` returns 0 rather than throwing, and the
    // read loop treats that as a no-op skip rather than an error.
    var buffer: CMBlockBuffer?
    let status = CMBlockBufferCreateEmpty(
        allocator: kCFAllocatorDefault, capacity: 0, flags: 0, blockBufferOut: &buffer)
    #expect(status == noErr)
    let empty = try #require(buffer)
    #expect(CMBlockBufferGetDataLength(empty) == 0)

    let scratch = AudioFileDecoder.SampleScratch()
    let length = try AudioFileDecoder.copyBytes(from: empty, into: scratch)
    #expect(length == 0)
}

// MARK: - Defect regression: partial frames must throw, not silently drop bytes.

@Test func frameCountComputesWholeFrames() throws {
    let frames = try AudioFileDecoder.frameCount(inByteCount: 32, frameSize: 8)
    #expect(frames == 4)
}

@Test func frameCountThrowsRatherThanTruncateOnPartialFrame() {
    // 17 bytes at an 8-byte frame size is 2 whole frames plus 1 leftover byte.
    // The original implementation computed `17 / 8 == 2` and silently
    // dropped that trailing byte; real LPCM sample buffers from AVFoundation
    // are always frame-aligned, so this should never happen, and if it ever
    // does, it must be surfaced rather than quietly losing real decoded data.
    #expect(throws: DecodeError.self) {
        _ = try AudioFileDecoder.frameCount(inByteCount: 17, frameSize: 8)
    }
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

#if !os(macOS)

/// The other half of `nativeFormats`, stated as a fact rather than an omission.
///
/// A platform difference that is only expressed by a shorter list is invisible:
/// nothing fails when it changes, in either direction. This fails if iOS starts
/// decoding Ogg Vorbis — which is the day `AudioFileTypes.supported` should stop
/// excluding it, and the day this test should be deleted.
@Test func oggVorbisDoesNotDecodeOnThisPlatform() async {
    await #expect(throws: (any Error).self) {
        _ = try await AudioFileDecoder.decode(url: fixture("sine.ogg"))
    }
}

#endif
