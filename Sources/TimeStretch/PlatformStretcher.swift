import ArtscribeKit

/// Which `TimeStretcher` this platform can actually provide.
///
/// The one place that chooses, mirroring `PlatformAudio` in `Playback`, so no
/// call site needs an `#if`.
///
/// ## macOS gets Rubber Band. Everywhere else gets Signalsmith.
///
/// Homebrew builds Rubber Band as a macOS dylib and nothing else, so an iOS
/// build cannot link it. Until the Signalsmith backend landed that meant iOS had
/// no stretcher at all and this returned `IdentityStretcher` — the transport
/// worked, the speed control moved, and *nothing got slower*, in an app whose
/// entire purpose is playing a passage slowly. That was a placeholder to develop
/// the iPad interface against and was never shippable.
///
/// It is now a real choice between two real engines rather than a fallback.
/// Signalsmith is vendored source that we compile, so it exists wherever Swift
/// does, and it is measured — `signalsmithPreservesPitch` — to hold pitch within
/// 0.05 cents at both half and double speed, which is Rubber Band R3 "Finer"
/// territory rather than a degraded substitute.
///
/// macOS still defaults to Rubber Band because that is what every existing
/// measurement, acceptance run and released build is against; changing the
/// default engine under a shipped product is a separate decision from making a
/// second engine available. The user-facing A/B — `StretchEngine` gaining a
/// `.signalsmith` case, and the Playback menu offering it — is deliberately not
/// part of this change; it touches sidecar persistence and the action catalog,
/// and belongs in its own pass.
///
/// `hasRealTimeStretching` used to live here, for a UI to ask before greying out
/// a speed control that could not work. It is **gone** rather than left
/// returning `true` everywhere: it had no callers, and a constant phrased as a
/// question is worse than no question at all — the next person to need one would
/// read it, believe it had been checked, and get an answer nothing computes.
/// Reinstate it when a platform can actually answer `false`.
public enum PlatformStretcher {

    /// The one translation between `StretchEngine` — four backends, a persisted
    /// user-visible name — and the two libraries that implement them.
    ///
    /// Exhaustive on purpose. A fifth engine has to be routed here before it
    /// compiles, which is the property the old `engine == .studio ? … : …`
    /// comparison did not have.
    public static func make(engine: StretchEngine) -> any TimeStretcher {
        switch engine {
        case .signalsmith:
            return SignalsmithStretcher(quality: .standard)
        case .signalsmithCheaper:
            return SignalsmithStretcher(quality: .cheaper)
        case .studio, .fast:
            #if canImport(CRubberBand)
            return RubberBandStretcher(core: engine == .fast ? .faster : .finer)
            #else
            // **A substitution, and it is not silent by accident.** A sidecar
            // written on a Mac carries `engine: "studio"`, and opening that file
            // on an iPad has to do *something* — there is no Rubber Band to
            // link. Signalsmith is the honest choice rather than refusing to
            // play, and it is the closer of the two in measured pitch accuracy
            // anyway.
            //
            // Nothing surfaces this to the user because nothing can select it
            // there: engine choice is developer-only and the iPad has no menu
            // bar to expose it. If engine choice ever becomes user-facing, this
            // is the branch that owes them a notice — spec §8.
            return SignalsmithStretcher(quality: .standard)
            #endif
        }
    }
}
