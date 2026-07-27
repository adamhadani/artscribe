import CRubberBand
import Testing

@Test func finerEngineIsR3() {
    let opts = RubberBandOptions(
        RubberBandOptionProcessRealTime.rawValue | RubberBandOptionEngineFiner.rawValue)
    let state = rubberband_new(44100, 2, opts, 1.0, 1.0)
    #expect(state != nil)
    defer { rubberband_delete(state) }
    #expect(rubberband_get_engine_version(state) == 3)
    #expect(rubberband_get_channel_count(state) == 2)
}

@Test func fasterEngineIsR2() {
    let opts = RubberBandOptions(
        RubberBandOptionProcessRealTime.rawValue | RubberBandOptionEngineFaster.rawValue)
    let state = rubberband_new(44100, 2, opts, 1.0, 1.0)
    #expect(state != nil)
    defer { rubberband_delete(state) }
    #expect(rubberband_get_engine_version(state) == 2)
}

@Test func realtimeModeReportsStartDelay() {
    let opts = RubberBandOptions(
        RubberBandOptionProcessRealTime.rawValue | RubberBandOptionEngineFiner.rawValue)
    let state = rubberband_new(44100, 2, opts, 1.0, 1.0)
    defer { rubberband_delete(state) }
    // R3 realtime reports a non-zero start delay that PlaybackEngine must compensate.
    #expect(rubberband_get_start_delay(state) > 0)
}
