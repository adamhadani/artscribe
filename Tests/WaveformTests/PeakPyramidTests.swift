import ArtscribeKit
import AudioDecode
import Foundation
import Testing

@testable import Waveform

/// Builds a DecodedAudio whose channel 0 is a known ramp and channel 1 its negation.
private func makeRamp(frames: Int) -> DecodedAudio {
    let storage = AudioStorage(channels: 2, capacityFrames: frames)
    for i in 0..<frames {
        let v = Float(i) / Float(frames)  // 0 ..< 1
        storage.pointer(0)[i] = v
        storage.pointer(1)[i] = -v
    }
    return DecodedAudio(
        channels: 2, sampleRate: 44100,
        frameCount: FrameIndex(frames), storage: storage)
}

@Test func baseLevelMatchesNaiveReference() {
    let frames = 4096
    let audio = makeRamp(frames: frames)
    let pyramid = PeakPyramid.build(audio)
    let base = pyramid.levels[0]
    #expect(base.bucketFrames == 256)
    #expect(base.bucketCount == frames / 256)

    // Naive reference for bucket 3 of channel 0.
    let b = 3
    var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
    for i in (b * 256)..<((b + 1) * 256) {
        lo = min(lo, audio.channel(0)[i]); hi = max(hi, audio.channel(0)[i])
    }
    #expect(abs(base.mins[0][b] - lo) < 1e-6)
    #expect(abs(base.maxs[0][b] - hi) < 1e-6)
}

@Test func higherLevelsAreConsistentWithBase() throws {
    let audio = makeRamp(frames: 65_536)
    let pyramid = PeakPyramid.build(audio)
    #expect(pyramid.levels.count >= 2)
    let base = pyramid.levels[0], next = pyramid.levels[1]
    #expect(next.bucketFrames == base.bucketFrames * 4)
    // Bucket 0 of `next` must span buckets 0..<4 of `base`.
    let expectedMax = try #require((0..<4).map { base.maxs[0][$0] }.max())
    #expect(abs(next.maxs[0][0] - expectedMax) < 1e-6)
}

@Test func levelSelectionPicksCoarsestThatStillResolves() {
    let audio = makeRamp(frames: 1_048_576)
    let pyramid = PeakPyramid.build(audio)
    // At 300 frames/pixel the 256-frame level resolves; 1024 would be too coarse.
    #expect(pyramid.level(forFramesPerPixel: 300).bucketFrames == 256)
    #expect(pyramid.level(forFramesPerPixel: 5000).bucketFrames == 4096)
    // Zoomed right in, fall back to the finest level available.
    #expect(pyramid.level(forFramesPerPixel: 1).bucketFrames == 256)
}

@Test func peaksSpanRequestedRange() {
    let audio = makeRamp(frames: 65_536)
    let pyramid = PeakPyramid.build(audio)
    let peaks = pyramid.peaks(
        channel: 0,
        range: FrameRange(start: 0, count: 65_536),
        buckets: 100)
    #expect(peaks.count == 100)
    // Ramp rises monotonically, so the last bucket must peak higher than the first.
    #expect(peaks[99].max > peaks[0].max)
    #expect(peaks[0].min >= 0)
}

@Test func negatedChannelHasNegativeMinima() throws {
    let audio = makeRamp(frames: 8192)
    let pyramid = PeakPyramid.build(audio)
    let peaks = pyramid.peaks(
        channel: 1,
        range: FrameRange(start: 0, count: 8192),
        buckets: 10)
    #expect(peaks.allSatisfy { $0.max <= 0.0001 })
    let last = try #require(peaks.last)
    #expect(last.min < -0.5)
}

@Test func emptyRangeYieldsSilentBuckets() {
    let audio = makeRamp(frames: 8192)
    let pyramid = PeakPyramid.build(audio)
    let peaks = pyramid.peaks(channel: 0, range: FrameRange(start: 0, count: 0), buckets: 5)
    #expect(peaks.count == 5)
    #expect(peaks.allSatisfy { $0.min == 0 && $0.max == 0 })
}

// MARK: - Defect regression: tail truncation must not drop real audio.

@Test func baseLevelCoversEveryFrameEvenWhenCountIsNotAMultipleOfBucketSize() throws {
    // 4196 is deliberately not a multiple of 256: floor(4196 / 256) == 16,
    // which would silently drop the trailing 100-frame partial bucket. The
    // pyramid must round up so every sample is represented somewhere.
    let frames = 4096 + 100
    let audio = makeRamp(frames: frames)
    let pyramid = PeakPyramid.build(audio)
    let base = pyramid.levels[0]

    let covered = base.bucketCount * base.bucketFrames
    #expect(
        covered >= frames,
        "pyramid base level only covers \(covered) of \(frames) frames -- tail dropped")

    // The tail of the ramp approaches 1.0. If the final partial bucket were
    // dropped, the max recorded anywhere in the base level would fall well
    // short of that, since the last *whole* bucket (index 15) only reaches
    // frame 4095 of 4196 (~0.976).
    let overallMax = try #require(base.maxs[0].max())
    #expect(
        overallMax > 0.99,
        "max over all base buckets is \(overallMax) -- the tail of the file is not represented")
}

@Test func reducedLevelsAlsoCoverEveryBaseBucketWhenCountIsNotAMultipleOfReductionFactor() throws {
    // 15 base buckets is not a multiple of the x4 reduction factor: floor(15/4)
    // == 3, which would silently drop the trailing 3 base buckets (indices
    // 12..<15) from level 1. The reduction step must round up too, or the
    // loss compounds at every coarser level.
    let frames = 256 * 15
    let audio = makeRamp(frames: frames)
    let pyramid = PeakPyramid.build(audio)
    let base = pyramid.levels[0]
    #expect(base.bucketCount == 15)
    let next = pyramid.levels[1]

    let coveredBaseBuckets = next.bucketCount * 4
    #expect(
        coveredBaseBuckets >= base.bucketCount,
        "level 1 only covers \(coveredBaseBuckets) of \(base.bucketCount) base buckets")

    let overallMax = try #require(next.maxs[0].max())
    #expect(
        overallMax > 0.99,
        "max over all level-1 buckets is \(overallMax) -- the tail of the file is not represented")
}

// MARK: - Real-media performance budget (gated on real material)

/// Not a fixture: points at real, copyrighted 24-bit/44.1 FLAC material that is
/// never committed to the repo. Skips cleanly when the environment variable is
/// unset, matching the pattern used in AudioDecodeTests.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ARTSCRIBE_TEST_MEDIA_DIR"] != nil))
func buildsPyramidForRealTrackWithinBudget() async throws {
    let dirPath = try #require(ProcessInfo.processInfo.environment["ARTSCRIBE_TEST_MEDIA_DIR"])
    let dir = URL(fileURLWithPath: dirPath)
    let flacFiles =
        try FileManager.default
        .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "flac" }
        .sorted { $0.path < $1.path }
    try #require(!flacFiles.isEmpty, "no .flac files found under \(dirPath)")

    let audio = try await AudioFileDecoder.decode(url: flacFiles[0])

    let start = Date()
    let pyramid = PeakPyramid.build(audio)
    let elapsed = Date().timeIntervalSince(start)

    // Budget from spec: whole open-to-render path under 2s; Task 4 measured
    // decode at 1.540s in release, leaving ~0.46s for pyramid construction.
    print("PeakPyramid.build took \(elapsed)s for \(audio.frameCount) frames")
    #expect(elapsed < 0.46, "pyramid build took \(elapsed)s, over the 0.46s budget")

    // Sanity: base level covers the whole file, no silent tail loss.
    let base = pyramid.levels[0]
    #expect(base.bucketCount * base.bucketFrames >= Int(audio.frameCount))
}
