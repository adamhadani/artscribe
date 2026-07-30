import ArtscribeKit

/// Which `TimeStretcher` this platform can actually provide.
///
/// The one place that chooses, mirroring `PlatformAudio` in `Playback`, so no
/// call site needs an `#if`.
///
/// ## macOS gets Rubber Band. iOS currently gets nothing.
///
/// **This is a real product gap, not a formality.** Homebrew builds Rubber Band
/// as a macOS dylib and nothing else, so an iOS build has no stretcher at all —
/// and time-stretching is not a feature of Artscribe, it is the *point* of
/// Artscribe. On iOS this returns `IdentityStretcher`, which plays the audio
/// back unaltered: the transport works, looping works, the speed control moves,
/// and **nothing gets slower**.
///
/// That is acceptable for a build that only has to compile and for developing
/// the iPad interface against. It is **not** acceptable to ship. Before an iPad
/// build reaches anybody:
///
/// - a portable backend has to exist behind `TimeStretcher` — Signalsmith
///   Stretch and Apple's own `AVAudioUnitTimePitch` are the two candidates
///   already agreed for A/B hearing tests — **or**
/// - `hasRealTimeStretching` has to be surfaced in the interface, because spec
///   §8 forbids degrading silently and a speed control that does nothing is
///   exactly that.
public enum PlatformStretcher {

    /// Whether this build can actually change playback speed.
    ///
    /// Exposed rather than inferred from `#if os(macOS)` at the call site: the
    /// answer will change when a portable backend lands, and it should change in
    /// one place. A UI that greys out the speed control, or explains itself,
    /// should ask this.
    public static var hasRealTimeStretching: Bool {
        #if canImport(CRubberBand)
        return true
        #else
        return false
        #endif
    }

    public static func make(engine: StretchEngine) -> any TimeStretcher {
        #if canImport(CRubberBand)
        return RubberBandStretcher(engine: engine)
        #else
        return IdentityStretcher()
        #endif
    }
}
