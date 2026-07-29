import Accelerate
import ArtscribeKit
import AudioDecode

/// Multi-resolution min/max peaks so the waveform can be drawn at any zoom
/// without touching the sample buffer. ~600 KB for a 10-minute stereo track.
public struct PeakPyramid: Sendable {

    public struct Peak: Sendable, Equatable {
        public var min: Float
        public var max: Float
    }

    public struct Level: Sendable {
        public let bucketFrames: Int
        /// Indexed [channel][bucket].
        public let mins: [[Float]]
        public let maxs: [[Float]]
        public var bucketCount: Int { mins.first?.count ?? 0 }
    }

    public static let baseBucketFrames = 256
    private static let reductionFactor = 4

    public let channels: Int
    public let frameCount: FrameIndex
    public let levels: [Level]

    /// Rounds up rather than truncating, so a partial final group (base
    /// buckets that don't divide evenly into `baseBucketFrames`, or bucket
    /// counts that don't divide evenly by `reductionFactor`) is still
    /// represented by a short final bucket instead of being silently
    /// dropped. Losing the tail here would mean the drawn waveform simply
    /// never shows the end of the file.
    private static func ceilDiv(_ a: Int, _ b: Int) -> Int {
        (a + b - 1) / b
    }

    public static func build(_ audio: DecodedAudio) -> PeakPyramid {
        let channels = audio.channels
        let total = Int(audio.frameCount)
        var levels: [Level] = []

        // Base level straight from the samples, using Accelerate. Ceiling
        // division so the final, possibly-short, bucket still exists.
        let baseBuckets = max(1, ceilDiv(total, baseBucketFrames))
        var baseMins = [[Float]](
            repeating: [Float](repeating: 0, count: baseBuckets), count: channels)
        var baseMaxs = baseMins

        for c in 0..<channels {
            let src = audio.channel(c)
            for b in 0..<baseBuckets {
                let offset = b * baseBucketFrames
                let n = Swift.min(baseBucketFrames, total - offset)
                guard n > 0 else { continue }
                var lo: Float = 0, hi: Float = 0
                vDSP_minv(src + offset, 1, &lo, vDSP_Length(n))
                vDSP_maxv(src + offset, 1, &hi, vDSP_Length(n))
                baseMins[c][b] = lo
                baseMaxs[c][b] = hi
            }
        }
        levels.append(Level(bucketFrames: baseBucketFrames, mins: baseMins, maxs: baseMaxs))

        // Coarser levels reduce the previous level rather than rescanning
        // samples. Ceiling division again: if `prev.bucketCount` isn't a
        // multiple of `reductionFactor`, the trailing group still becomes a
        // (smaller) final bucket rather than being dropped -- otherwise the
        // loss from the base level would compound at every level above it.
        while levels[levels.count - 1].bucketCount > reductionFactor {
            let prev = levels[levels.count - 1]
            let count = ceilDiv(prev.bucketCount, reductionFactor)
            var mins = [[Float]](repeating: [Float](repeating: 0, count: count), count: channels)
            var maxs = mins
            for c in 0..<channels {
                for b in 0..<count {
                    var lo = Float.greatestFiniteMagnitude
                    var hi = -Float.greatestFiniteMagnitude
                    for k in 0..<reductionFactor {
                        let i = b * reductionFactor + k
                        guard i < prev.bucketCount else { break }
                        lo = Swift.min(lo, prev.mins[c][i])
                        hi = Swift.max(hi, prev.maxs[c][i])
                    }
                    mins[c][b] = lo
                    maxs[c][b] = hi
                }
            }
            levels.append(
                Level(
                    bucketFrames: prev.bucketFrames * reductionFactor,
                    mins: mins, maxs: maxs))
        }

        return PeakPyramid(channels: channels, frameCount: audio.frameCount, levels: levels)
    }

    /// Coarsest level whose buckets are still no wider than one pixel.
    public func level(forFramesPerPixel fpp: Double) -> Level {
        var chosen = levels[0]
        for level in levels where Double(level.bucketFrames) <= fpp {
            chosen = level
        }
        return chosen
    }

    /// Aggregated peaks for a time range, resampled to exactly `buckets` entries.
    public func peaks(channel: Int, range: FrameRange, buckets: Int) -> [Peak] {
        guard buckets > 0, channel < channels else { return [] }
        var out = [Peak](repeating: Peak(min: 0, max: 0), count: buckets)
        let clamped = range.clamped(to: frameCount)
        guard !clamped.isEmpty else { return out }

        let fpp = Double(clamped.count) / Double(buckets)
        let level = level(forFramesPerPixel: fpp)
        let mins = level.mins[channel], maxs = level.maxs[channel]
        let bucketCount = level.bucketCount
        guard bucketCount > 0 else { return out }

        for i in 0..<buckets {
            let startFrame = Double(clamped.start) + Double(i) * fpp
            let endFrame = startFrame + fpp
            // Every level covers the full file (see `build`), so these
            // indices are always in range; the clamps below are cheap
            // defensive insurance, not load-bearing for correctness.
            let lo = Swift.max(0, Swift.min(bucketCount - 1, Int(startFrame) / level.bucketFrames))
            let hi = Swift.max(0, Swift.min(bucketCount - 1, Int(endFrame) / level.bucketFrames))
            guard lo <= hi else { continue }
            var mn = Float.greatestFiniteMagnitude
            var mx = -Float.greatestFiniteMagnitude
            for b in lo...hi {
                mn = Swift.min(mn, mins[b])
                mx = Swift.max(mx, maxs[b])
            }
            out[i] = Peak(min: mn, max: mx)
        }
        return out
    }
}
