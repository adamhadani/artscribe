import Testing

@testable import ArtscribeKit

@Test func defaultsToFullSpeedStudio() {
    let s = SpeedState()
    #expect(s.ratio == 1.0)
    #expect(s.timeRatio == 1.0)
    #expect(s.engine == .studio)
}

@Test func timeRatioIsReciprocalOfSpeed() {
    var s = SpeedState()
    s.setRatio(0.5)
    #expect(s.ratio == 0.5)
    #expect(s.timeRatio == 2.0)  // half speed => twice as long
    s.setRatio(2.0)
    #expect(s.timeRatio == 0.5)
}

@Test func stepClampsAtBounds() {
    var s = SpeedState()
    s.setRatio(SpeedState.minRatio)
    s.step(by: -0.05)
    #expect(s.ratio == SpeedState.minRatio)
    s.setRatio(SpeedState.maxRatio)
    s.step(by: 0.05)
    #expect(s.ratio == SpeedState.maxRatio)
}

@Test func setRatioClampsOutOfRangeInput() {
    var s = SpeedState()
    s.setRatio(99)
    #expect(s.ratio == SpeedState.maxRatio)
    s.setRatio(0)
    #expect(s.ratio == SpeedState.minRatio)
}

@Test func stepMovesByExactDelta() {
    var s = SpeedState()
    s.step(by: -0.05)
    #expect(abs(s.ratio - 0.95) < 1e-9)
}

@Test func boundsMatchSpec() {
    #expect(SpeedState.minRatio == 0.10)
    #expect(SpeedState.maxRatio == 2.00)
}
