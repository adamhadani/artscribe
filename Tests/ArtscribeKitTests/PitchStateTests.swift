import Foundation
import Testing

@testable import ArtscribeKit

@Suite("Pitch")
struct PitchStateTests {

    /// The whole point of the type: pitch is expressed as an equal-tempered
    /// ratio, and an octave is exactly a doubling.
    @Test("an octave up doubles, an octave down halves")
    func octaves() {
        #expect(abs(PitchState(cents: 1200).scale - 2.0) < 1e-9)
        #expect(abs(PitchState(cents: -1200).scale - 0.5) < 1e-9)
        #expect(PitchState(cents: 0).scale == 1.0)
    }

    /// A semitone is the twelfth root of two. Getting this wrong is inaudible at
    /// one semitone and glaring at twelve, which is exactly the kind of error
    /// that ships.
    @Test("a semitone is the twelfth root of two")
    func semitone() {
        let expected = 1.059_463_094_359_295_3
        #expect(abs(PitchState(cents: 100).scale - expected) < 1e-9)
        // And twelve of them compose back to an octave.
        var scale = 1.0
        for _ in 0..<12 { scale *= PitchState(cents: 100).scale }
        #expect(abs(scale - 2.0) < 1e-6)
    }

    /// Unlike `SpeedState`, this is **not** a reciprocal — up is up. The
    /// speed/time-ratio inversion is the easiest audible bug in the project and
    /// this asserts pitch does not share it.
    @Test("raising the pitch raises the scale, with no inversion")
    func upIsUp() {
        #expect(PitchState(cents: 700).scale > 1.0)
        #expect(PitchState(cents: -700).scale < 1.0)
    }

    @Test("the range is clamped at one octave either way")
    func clamping() {
        #expect(PitchState(cents: 5000).cents == 1200)
        #expect(PitchState(cents: -5000).cents == -1200)
        var pitch = PitchState(cents: 1200)
        let moved = pitch.adjust(byCents: 100)
        #expect(!moved, "at the ceiling it must report no movement")
        #expect(pitch.cents == 1200)
    }

    /// Cents rather than a Double of semitones, so repeated presses stay exact.
    @Test("a hundred one-cent steps land exactly on a semitone")
    func integerCentsDoNotDrift() {
        var pitch = PitchState()
        for _ in 0..<100 { _ = pitch.adjust(byCents: 1) }
        #expect(pitch.cents == 100)
        #expect(pitch.semitones == 1)
        #expect(pitch.centsRemainder == 0)
    }

    @Test("display splits into semitones and remainder, including downwards")
    func displaySplit() {
        let down = PitchState(cents: -350)
        #expect(down.semitones == -3)
        #expect(down.centsRemainder == -50)
        #expect(PitchState(cents: 0).isAltered == false)
        #expect(PitchState(cents: -1).isAltered)
    }

    /// The sidecar is hand-editable, so the decoder cannot trust it.
    @Test("a decoded out-of-range value is clamped, and an absent one is zero")
    func decoding() throws {
        let decoder = JSONDecoder()
        let wild = try decoder.decode(PitchState.self, from: Data(#"{"cents": 99999}"#.utf8))
        #expect(wild.cents == 1200)
        let absent = try decoder.decode(PitchState.self, from: Data("{}".utf8))
        #expect(absent.cents == 0)
    }
}
