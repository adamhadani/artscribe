import ArtscribeKit

public struct RulerTick: Equatable, Sendable {
    public let frame: FrameIndex
    public let isMajor: Bool
    /// Only major ticks are labelled; minor ticks carry `nil`.
    public let label: String?
}

/// Chooses tick spacing for the time ruler and lays the ticks out in frames.
///
/// Pure, so the choice of spacing across the whole zoom range can be tested
/// without a view. Intervals come from a fixed ladder of musically and clock-wise
/// readable durations — never a computed `pow(10,)` step, which produces labels
/// like `00:03.750`.
public enum RulerTicks {

    /// Major interval in seconds, paired with how many minor divisions sit inside
    /// it. Divisions are chosen so every minor tick lands on a value a musician
    /// would recognise (quarters of a second, thirds of a minute, and so on).
    static let ladder: [(interval: Double, divisions: Int)] = [
        (0.001, 5), (0.002, 4), (0.005, 5), (0.01, 5), (0.02, 4), (0.05, 5),
        (0.1, 5), (0.2, 4), (0.5, 5), (1, 5), (2, 4), (5, 5), (10, 5), (15, 3),
        (30, 3), (60, 4), (120, 4), (300, 5), (600, 5), (900, 3), (1800, 3),
        (3600, 4)
    ]

    /// Smallest ladder entry whose major ticks are at least `minSpacing` points
    /// apart. Falls back to the coarsest entry for absurdly long files rather
    /// than emitting an unreadable wall of labels.
    public static func majorInterval(
        secondsPerPixel: Double,
        minSpacing: Double
    ) -> (interval: Double, divisions: Int) {
        guard secondsPerPixel > 0, secondsPerPixel.isFinite, minSpacing > 0 else {
            return ladder[0]
        }
        let wanted = secondsPerPixel * minSpacing
        for entry in ladder where entry.interval >= wanted { return entry }
        return ladder[ladder.count - 1]
    }

    /// Ticks covering the viewport, in ascending frame order.
    ///
    /// `minSpacing` is in points and applies to *labelled* ticks; minor ticks are
    /// correspondingly denser.
    public static func ticks(
        viewport: Viewport,
        sampleRate: Double,
        minSpacing: Double = 84
    ) -> [RulerTick] {
        guard sampleRate > 0, sampleRate.isFinite, viewport.totalFrames > 0 else { return [] }
        let secondsPerPixel = viewport.framesPerPixel / sampleRate
        let (interval, divisions) = majorInterval(
            secondsPerPixel: secondsPerPixel, minSpacing: minSpacing)
        let minor = interval / Double(divisions)
        guard minor > 0, minor.isFinite else { return [] }

        let startSeconds = Double(viewport.startFrame) / sampleRate
        let endSeconds = Double(viewport.endFrame) / sampleRate
        let firstStep = Int64((startSeconds / minor).rounded(.down))
        let lastStep = Int64((endSeconds / minor).rounded(.up))
        // `minSpacing` already bounds this to roughly width/minSpacing*divisions
        // entries; the cap only guards against a pathological sample rate.
        guard lastStep >= firstStep, lastStep - firstStep < 10_000 else { return [] }

        var ticks: [RulerTick] = []
        ticks.reserveCapacity(Int(lastStep - firstStep) + 1)
        for step in firstStep...lastStep {
            let seconds = Double(step) * minor
            let frame = FrameIndex((seconds * sampleRate).rounded())
            guard frame >= viewport.startFrame, frame <= viewport.endFrame else { continue }
            guard frame >= 0, frame <= viewport.totalFrames else { continue }
            let isMajor = step % Int64(divisions) == 0
            let label =
                isMajor
                ? (interval < 1
                    ? TimeCode.precise(seconds: seconds) : TimeCode.coarse(seconds: seconds))
                : nil
            ticks.append(RulerTick(frame: frame, isMajor: isMajor, label: label))
        }
        return ticks
    }
}
