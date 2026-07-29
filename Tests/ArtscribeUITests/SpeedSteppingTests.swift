import ArtscribeKit
import Testing

@testable import ArtscribeUI

/// The `Q`/`W`/`⇧Q`/`⇧W`/`1`–`4` cluster.
///
/// `SpeedState` already clamps and already owns `timeRatio`; what is tested here
/// is the *stepping policy* on top of it — the increments, the presets, and the
/// quantisation that stops repeated stepping from drifting the readout off the
/// grid it claims to be on.
@Suite("Speed stepping")
struct SpeedSteppingTests {

    @Test("a coarse step is 5 percentage points, a fine step is 1")
    func stepSizes() {
        #expect(SpeedStepping.coarse == 0.05)
        #expect(SpeedStepping.fine == 0.01)
    }

    @Test("stepping down and back up returns to exactly the starting ratio")
    func steppingRoundTrips() {
        var speed = SpeedState()
        speed = SpeedStepping.stepped(speed, by: -SpeedStepping.coarse)
        #expect(speed.ratio == 0.95)
        speed = SpeedStepping.stepped(speed, by: SpeedStepping.coarse)
        #expect(speed.ratio == 1.0)
    }

    /// Binary floating point cannot represent 0.05, so eighteen naive
    /// subtractions from 1.0 land at 0.09999999999999995 — which clamps to 0.10
    /// and hides the drift, while nine of them land at 0.5500000000000002 and do
    /// not. Quantising to the nearest thousandth keeps every reachable ratio on
    /// the grid the readout displays.
    @Test("repeated coarse steps stay exactly on the 5% grid")
    func steppingDoesNotDrift() {
        var speed = SpeedState()
        var reached: [Double] = []
        for _ in 0..<9 {
            speed = SpeedStepping.stepped(speed, by: -SpeedStepping.coarse)
            reached.append(speed.ratio)
        }
        #expect(reached == [0.95, 0.90, 0.85, 0.80, 0.75, 0.70, 0.65, 0.60, 0.55])
    }

    @Test("repeated fine steps stay exactly on the 1% grid")
    func fineSteppingDoesNotDrift() {
        var speed = SpeedState()
        for _ in 0..<7 {
            speed = SpeedStepping.stepped(speed, by: -SpeedStepping.fine)
        }
        #expect(speed.ratio == 0.93)
    }

    @Test("stepping clamps at the ends of the range rather than wrapping or drifting past")
    func steppingClamps() {
        var slow = SpeedState(ratio: SpeedState.minRatio)
        slow = SpeedStepping.stepped(slow, by: -SpeedStepping.coarse)
        #expect(slow.ratio == SpeedState.minRatio)

        var fast = SpeedState(ratio: SpeedState.maxRatio)
        fast = SpeedStepping.stepped(fast, by: SpeedStepping.coarse)
        #expect(fast.ratio == SpeedState.maxRatio)
    }

    @Test("stepping preserves the engine")
    func steppingPreservesEngine() {
        let speed = SpeedStepping.stepped(SpeedState(ratio: 1.0, engine: .fast), by: -0.05)
        #expect(speed.engine == .fast)
    }

    @Test("the four presets are 100, 75, 50 and 33 percent")
    func presets() {
        #expect(SpeedStepping.presets == [1.00, 0.75, 0.50, 0.33])
    }

    /// The single easiest bug in this project: `timeRatio == 1 / ratio`. Asserted
    /// here at the exact ratio the acceptance run listens at, so a swap shows up
    /// as a failing test rather than as double-speed playback.
    @Test("half speed is a time ratio of two, not a half")
    func timeRatioIsTheReciprocal() {
        let speed = SpeedState(ratio: 0.5)
        #expect(speed.timeRatio == 2.0)
    }

    @Test("the readout rounds to whole percent")
    func percentLabel() {
        #expect(SpeedStepping.percentLabel(1.0) == "100%")
        #expect(SpeedStepping.percentLabel(0.33) == "33%")
        #expect(SpeedStepping.percentLabel(0.995) == "100%")
    }

    @Test("a preset is only reported active when the ratio matches it exactly")
    func activePreset() {
        #expect(SpeedStepping.isActive(preset: 0.5, ratio: 0.5))
        #expect(!SpeedStepping.isActive(preset: 0.5, ratio: 0.51))
        // 0.33 is not representable; the preset must still match after a round trip.
        var speed = SpeedState()
        speed.setRatio(SpeedStepping.presets[3])
        #expect(SpeedStepping.isActive(preset: 0.33, ratio: speed.ratio))
    }

    // MARK: - Emphasis

    /// The status bar shouts about a speed that is not 100%, so the question
    /// "is this speed altered?" has to be exactly as tolerant as the menu's
    /// checkmark — otherwise a ratio can be both "100%" in the readout and
    /// emphasised as if it were not.
    @Test("100% is not altered, anything else is")
    func alteredSpeed() {
        #expect(SpeedStepping.isAltered(1.0) == false)
        #expect(SpeedStepping.isAltered(0.5) == true)
        #expect(SpeedStepping.isAltered(1.25) == true)
        #expect(SpeedStepping.isAltered(0.99) == true)
    }

    /// A ratio a hair off 1.0 still reads as "100%", so it must not be
    /// emphasised: the emphasis means something only while it agrees with the
    /// number beside it.
    @Test("a ratio that still reads as 100% is not emphasised")
    func alteredMatchesTheReadout() {
        let almost = 1.0 + 0.4 / 1000
        #expect(SpeedStepping.percentLabel(almost) == "100%")
        #expect(SpeedStepping.isAltered(almost) == false)
    }

    /// Never degrade silently: a nonsense ratio is not "normal speed".
    @Test("a non-finite ratio counts as altered")
    func alteredOnNonFinite() {
        #expect(SpeedStepping.isAltered(.nan) == true)
    }

    @Test("every preset but 100% is emphasised")
    func alteredPresets() {
        for preset in SpeedStepping.presets {
            #expect(SpeedStepping.isAltered(preset) == (preset != 1.0))
        }
    }
}
