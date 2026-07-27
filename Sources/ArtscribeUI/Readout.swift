/// Number formatting shared by the readouts, alongside `TimeCode` which owns
/// time. One place, so the speed and volume fields cannot drift apart in how
/// they round.
public enum Readout {

    /// A 0…1 ratio as whole percent. Never silently zero on a bad value.
    public static func percent(_ ratio: Double) -> String {
        guard ratio.isFinite else { return "—" }
        return "\(Int((ratio * 100).rounded()))%"
    }
}
