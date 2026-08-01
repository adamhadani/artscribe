import Foundation  // JSONEncoder/JSONDecoder — the sidecar's own format
import Testing

@testable import ArtscribeKit

/// `StretchEngine`'s raw values are written into `.artscripture` sidecars, which
/// are user-visible files people are invited to hand-edit (spec §7). They are
/// therefore a compatibility surface, not an implementation detail.
@Suite("Stretch engine")
struct StretchEngineTests {

    /// Pinned literally, on purpose. A rename refactor would sail through every
    /// other test in the project — the enum is used symbolically everywhere —
    /// and quietly turn every saved sidecar's engine back into the default.
    @Test("raw values are stable")
    func rawValues() {
        #expect(StretchEngine.studio.rawValue == "studio")
        #expect(StretchEngine.fast.rawValue == "fast")
        #expect(StretchEngine.signalsmith.rawValue == "signalsmith")
        #expect(StretchEngine.signalsmithCheaper.rawValue == "signalsmithCheaper")
    }

    /// The forward-compatibility promise that makes adding a backend safe: a
    /// sidecar naming an engine this build has never heard of loads on the
    /// default rather than failing, so a file written by a newer Artscripture still
    /// opens in an older one and keeps its loop points.
    @Test("an unknown engine decodes as studio, and the rest of the payload survives")
    func unknownEngineFallsBack() throws {
        let json = #"{"ratio":0.5,"engine":"someFutureBackend"}"#
        let decoded = try JSONDecoder().decode(SpeedState.self, from: Data(json.utf8))
        #expect(decoded.engine == .studio)
        #expect(decoded.ratio == 0.5, "the ratio must not be lost with the engine")
    }

    @Test(
        "every engine round-trips through the sidecar encoding", arguments: StretchEngine.allCases)
    func roundTrip(engine: StretchEngine) throws {
        var state = SpeedState()
        state.setRatio(0.75)
        state.engine = engine
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SpeedState.self, from: data)
        #expect(decoded.engine == engine)
        #expect(decoded.ratio == 0.75)
    }

    /// `usesRubberBand` decides what an iOS build can honour, so it has to be
    /// right for every case rather than for the two anyone was thinking about.
    @Test("only the Rubber Band cases claim Rubber Band")
    func rubberBandClaims() {
        #expect(StretchEngine.studio.usesRubberBand)
        #expect(StretchEngine.fast.usesRubberBand)
        #expect(!StretchEngine.signalsmith.usesRubberBand)
        #expect(!StretchEngine.signalsmithCheaper.usesRubberBand)
    }

    /// Names are what a developer picks from in the menu and passes to
    /// `artscribe-cli --engine`. Two engines sharing a name, or one falling back
    /// to a raw value, would make the A/B unreadable.
    @Test("display names are present and distinct")
    func displayNames() {
        let names = StretchEngine.allCases.map(\.displayName)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == StretchEngine.allCases.count)
    }
}
