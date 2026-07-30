import ArtscribeKit
import Testing

@testable import TimeStretch

/// `PlatformStretcher.make` is the only translation between `StretchEngine` —
/// four named backends, persisted in user sidecars — and the two libraries that
/// implement them. Getting it wrong is silent: the app plays, at the right
/// speed, on the wrong engine, and the only symptom is that an A/B comparison
/// quietly compares something with itself.
///
/// That is not hypothetical. The mapping used to be
/// `engine == .studio ? Finer : Faster` inside `RubberBandStretcher`, so every
/// engine that was not `.studio` — including, once Signalsmith existed, both of
/// its cases — would have built R2 Faster.
@Test(arguments: StretchEngine.allCases)
func everyEngineMapsToTheLibraryItNames(engine: StretchEngine) {
    let stretcher = PlatformStretcher.make(engine: engine)

    #if canImport(CRubberBand)
    if engine.usesRubberBand {
        #expect(
            stretcher is RubberBandStretcher,
            "\(engine.rawValue) names Rubber Band but built \(type(of: stretcher))")
    } else {
        #expect(
            stretcher is SignalsmithStretcher,
            "\(engine.rawValue) names Signalsmith but built \(type(of: stretcher))")
    }
    #else
    // No Rubber Band to link, so every engine — including the two that name it —
    // resolves to Signalsmith. Documented in `PlatformStretcher.make`; asserted
    // here so the substitution stays deliberate rather than becoming a crash.
    #expect(stretcher is SignalsmithStretcher)
    #endif
}

/// Whatever it built has to be usable, not merely of the right type. A backend
/// that reports a start delay it cannot honour, or that produces nothing, would
/// pass the type check above and fail in the render loop.
@Test(arguments: StretchEngine.allCases)
func everyEngineConfiguresAndProduces(engine: StretchEngine) {
    let stretcher = PlatformStretcher.make(engine: engine)
    stretcher.configure(sampleRate: 44100, channels: 1, maxBlock: 512)
    stretcher.timeRatio = 2.0

    let out = runStretcher(
        stretcher, input: sine(freq: 440, seconds: 0.5, sampleRate: 44100),
        sampleRate: 44100, block: 512)

    #expect(!out.isEmpty, "\(engine.rawValue) produced no output")
    #expect(!out.contains { !$0.isFinite }, "\(engine.rawValue) produced NaN or infinity")
    #expect(stretcher.startDelay >= 0)
}
