import ArtscribeKit

/// Time formatting for every readout in the UI.
///
/// Pure and unit-tested: no view formats time itself. Rounding happens once, in
/// the smallest unit actually displayed, so a value like 59.9996 s reads
/// `01:00.000` rather than the impossible `00:60.000`.
public enum TimeCode {

    /// The string shown when a value cannot be expressed (NaN, infinity, or a
    /// magnitude past what the counter can represent). Never silently zero.
    public static let placeholder = "--:--"

    /// `mm:ss.SSS`, widening to `h:mm:ss.SSS` past an hour.
    public static func precise(seconds: Double) -> String {
        format(seconds: seconds, showsMilliseconds: true)
    }

    /// `mm:ss`, widening to `h:mm:ss` past an hour.
    public static func coarse(seconds: Double) -> String {
        format(seconds: seconds, showsMilliseconds: false)
    }

    public static func precise(frames: FrameIndex, sampleRate: Double) -> String {
        precise(seconds: seconds(frames: frames, sampleRate: sampleRate))
    }

    public static func coarse(frames: FrameIndex, sampleRate: Double) -> String {
        coarse(seconds: seconds(frames: frames, sampleRate: sampleRate))
    }

    /// Frames are the source of truth everywhere else; this is the only place
    /// they become seconds, and it refuses to divide by a bogus sample rate.
    public static func seconds(frames: FrameIndex, sampleRate: Double) -> Double {
        guard sampleRate > 0, sampleRate.isFinite else { return .nan }
        return Double(frames) / sampleRate
    }

    private static func format(seconds: Double, showsMilliseconds: Bool) -> String {
        guard seconds.isFinite else { return placeholder }
        let unitsPerSecond: Double = showsMilliseconds ? 1000 : 1
        let total = (abs(seconds) * unitsPerSecond).rounded()
        guard total < Double(Int64.max) else { return placeholder }

        var units = Int64(total)
        let milliseconds = showsMilliseconds ? units % 1000 : 0
        if showsMilliseconds { units /= 1000 }
        let secs = units % 60
        let mins = (units / 60) % 60
        let hours = units / 3600

        var out = seconds < 0 ? "-" : ""
        if hours > 0 {
            out += "\(hours):" + pad(mins, 2)
        } else {
            out += pad(mins, 2)
        }
        out += ":" + pad(secs, 2)
        if showsMilliseconds { out += "." + pad(milliseconds, 3) }
        return out
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        let digits = String(value)
        guard digits.count < width else { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }
}
