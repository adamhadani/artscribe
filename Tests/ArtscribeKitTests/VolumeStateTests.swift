import Foundation
import Testing

@testable import ArtscribeKit

/// Output level, mute, and the two step sizes behind `↑`/`↓` and `⇧↑`/`⇧↓`.
///
/// The taper is deliberately **linear in amplitude**: the slider position *is*
/// the mixer gain, so "50%" means half of full scale and nothing else. See
/// `VolumeState.amplitude` for why that reading was chosen over a dB curve.
@Suite("Volume")
struct VolumeStateTests {

    @Test("a fresh volume is half scale, not full — nothing blasts on first launch")
    func defaultIsHalfScale() {
        let volume = VolumeState()
        #expect(volume.level == 0.5)
        #expect(volume.amplitude == 0.5)
        #expect(!volume.isMuted)
    }

    @Test("a coarse step is 5 points and a fine step is 1")
    func stepSizes() {
        #expect(VolumeState.coarseStep == 0.05)
        #expect(VolumeState.fineStep == 0.01)
        #expect(VolumeState.fineStep < VolumeState.coarseStep)
    }

    @Test("stepping up and back down returns to exactly the starting level")
    func steppingRoundTrips() {
        var volume = VolumeState()
        volume.step(by: VolumeState.coarseStep)
        #expect(volume.level == 0.55)
        volume.step(by: -VolumeState.coarseStep)
        #expect(volume.level == 0.5)
    }

    /// Same reason as `SpeedStepping`: neither 0.05 nor 0.01 is representable, so
    /// naive repeated addition walks off the grid the readout claims to show.
    @Test("repeated steps stay exactly on the grid")
    func steppingDoesNotDrift() {
        var volume = VolumeState()
        var reached: [Double] = []
        for _ in 0..<5 {
            volume.step(by: VolumeState.coarseStep)
            reached.append(volume.level)
        }
        #expect(reached == [0.55, 0.60, 0.65, 0.70, 0.75])

        var fine = VolumeState()
        for _ in 0..<7 { fine.step(by: -VolumeState.fineStep) }
        #expect(fine.level == 0.43)
    }

    @Test("a fine step really is finer than a coarse one")
    func fineIsFiner() {
        var coarse = VolumeState()
        coarse.step(by: VolumeState.coarseStep)
        var fine = VolumeState()
        fine.step(by: VolumeState.fineStep)
        #expect(fine.level - 0.5 < coarse.level - 0.5)
        #expect(fine.level == 0.51)
    }

    @Test("stepping clamps at silence and at full scale")
    func steppingClamps() {
        var loud = VolumeState(level: 1.0)
        loud.step(by: VolumeState.coarseStep)
        #expect(loud.level == 1.0)

        var quiet = VolumeState(level: 0.0)
        quiet.step(by: -VolumeState.coarseStep)
        #expect(quiet.level == 0.0)
        #expect(quiet.amplitude == 0.0)
    }

    @Test("an out-of-range or non-finite level is clamped rather than accepted")
    func initClamps() {
        #expect(VolumeState(level: 4).level == 1.0)
        #expect(VolumeState(level: -1).level == 0.0)
        #expect(VolumeState(level: .nan).level == VolumeState.defaultLevel)
    }

    // MARK: - Mute

    @Test("mute silences the output without forgetting the level")
    func muteKeepsTheLevel() {
        var volume = VolumeState(level: 0.8)
        volume.toggleMute()
        #expect(volume.isMuted)
        #expect(volume.amplitude == 0.0)
        // The *level* is untouched, so the slider and readout still say 80%.
        #expect(volume.level == 0.8)
    }

    @Test("unmuting restores the prior level rather than jumping to full scale")
    func unmuteRestores() {
        var volume = VolumeState(level: 0.23)
        volume.toggleMute()
        volume.toggleMute()
        #expect(!volume.isMuted)
        #expect(volume.level == 0.23)
        #expect(volume.amplitude == 0.23)
    }

    /// Pressing volume-up while muted should make sound, the way every other
    /// piece of hardware and software behaves — not silently move a hidden level.
    @Test("stepping while muted unmutes")
    func steppingUnmutes() {
        var volume = VolumeState(level: 0.4)
        volume.toggleMute()
        volume.step(by: VolumeState.coarseStep)
        #expect(!volume.isMuted)
        #expect(volume.level == 0.45)
        #expect(volume.amplitude == 0.45)
    }

    @Test("dragging the slider while muted unmutes")
    func settingLevelUnmutes() {
        var volume = VolumeState(level: 0.4)
        volume.toggleMute()
        volume.setLevel(0.9)
        #expect(!volume.isMuted)
        #expect(volume.amplitude == 0.9)
    }

    @Test("muting at silence and unmuting again gives back silence, not a surprise")
    func muteAtZeroIsHonest() {
        var volume = VolumeState(level: 0)
        volume.toggleMute()
        volume.toggleMute()
        #expect(volume.level == 0)
    }

    // MARK: - Persistence

    @Test("a hand-edited sidecar cannot smuggle an out-of-range level past the clamp")
    func decodingClamps() throws {
        let json = #"{"level": 9.5, "isMuted": false, "levelBeforeMute": -3}"#
        let decoded = try JSONDecoder().decode(VolumeState.self, from: Data(json.utf8))
        #expect(decoded.level == 1.0)
        decoded.roundTripIsStable()
    }

    @Test("encodes and decodes back to the same value")
    func roundTrips() throws {
        var volume = VolumeState(level: 0.37)
        volume.toggleMute()
        let data = try JSONEncoder().encode(volume)
        #expect(try JSONDecoder().decode(VolumeState.self, from: data) == volume)
    }
}

extension VolumeState {
    /// Unmuting after a clamped decode must land somewhere representable.
    fileprivate func roundTripIsStable() {
        var copy = self
        copy.toggleMute()
        copy.toggleMute()
        #expect(copy.level >= VolumeState.minLevel && copy.level <= VolumeState.maxLevel)
    }
}
