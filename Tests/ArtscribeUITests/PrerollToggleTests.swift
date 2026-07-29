import ArtscribeKit
import AudioDecode
import Foundation
import Testing
import Waveform

@testable import ArtscribeUI

/// The **mode**, as distinct from the amount.
///
/// `Preroll.minimumSeconds` is 0 and means off, so a toggle can look redundant.
/// It is not: reaching zero forgets the seconds the user chose, and this is a
/// mode flipped while working. These tests pin that difference, because it is
/// the whole reason the toggle exists and it would be invisible otherwise.
@MainActor
struct PrerollToggleTests {

    /// A loaded model with no audio session — `loadForTesting` leaves it nil, so
    /// these cover the decision-making half without opening a device.
    private func model(seconds: Double = 2) -> ViewerModel {
        let frames: FrameIndex = 441_000
        let storage = AudioStorage(channels: 1, capacityFrames: Int(frames))
        let audio = DecodedAudio(
            channels: 1, sampleRate: 44100, frameCount: frames, storage: storage)
        let model = ViewerModel()
        model.loadForTesting(audio: audio, pyramid: PeakPyramid.build(audio), widthPixels: 1000)
        model.prefs.prerollSeconds = seconds
        return model
    }

    @Test("the preroll ships on")
    func defaultsOn() {
        #expect(model().prefs.prerollEnabled)
    }

    @Test("toggling off then on restores the amount rather than a default")
    func toggleKeepsTheAmount() {
        let model = model(seconds: 0.75)
        model.togglePreroll()
        #expect(!model.prefs.prerollEnabled)
        #expect(model.prefs.prerollSeconds == 0.75, "turning it off must not forget the amount")
        model.togglePreroll()
        #expect(model.prefs.prerollEnabled)
        #expect(model.prefs.prerollSeconds == 0.75)
    }

    @Test("a stored mode round-trips, and absent means on")
    func persistenceRoundTrips() throws {
        let suite = try #require(UserDefaults(suiteName: "preroll.toggle.\(UUID().uuidString)"))
        defer { suite.removePersistentDomain(forName: suite.description) }
        let store = PrerollSettings(defaults: suite)
        #expect(store.loadEnabled(), "absent must read as on, not as false")
        store.saveEnabled(false)
        #expect(!store.loadEnabled())
        store.saveEnabled(true)
        #expect(store.loadEnabled())
    }
}
