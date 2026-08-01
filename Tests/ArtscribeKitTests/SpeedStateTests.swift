import Foundation
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

// Guards against a linear-reflection formula (e.g. `2.5 - ratio`) that would
// satisfy the symmetric 0.5<->2.0 pair above but is not the true reciprocal.
@Test func timeRatioIsReciprocalAtAnAsymmetricPoint() {
    var s = SpeedState()
    s.setRatio(0.25)
    #expect(s.timeRatio == 4.0)
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

// SpeedState is persisted in a visible, user-editable .artscripture file (design
// spec §7), so hand-edited or corrupted JSON is expected input. Decoding must
// route through the same clamp as setRatio/init, not bypass it.
@Test func decodingClampsOutOfRangeRatioAboveMax() throws {
    let json = Data(#"{"ratio": 99, "engine": "studio"}"#.utf8)
    let decoded = try JSONDecoder().decode(SpeedState.self, from: json)
    #expect(decoded.ratio == SpeedState.maxRatio)
}

@Test func decodingClampsZeroRatioToFiniteTimeRatio() throws {
    let json = Data(#"{"ratio": 0, "engine": "studio"}"#.utf8)
    let decoded = try JSONDecoder().decode(SpeedState.self, from: json)
    #expect(decoded.ratio == SpeedState.minRatio)
    #expect(decoded.timeRatio.isFinite)
}
