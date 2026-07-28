import Testing

@testable import ArtscribeKit

/// The pure half of session persistence (spec §7): what a decoded `.artscribe`
/// payload is allowed to install, and what it is forced to give up.
///
/// The file is user-editable by design, so *every* value arriving here is
/// untrusted. These tests are written from that angle — the interesting cases
/// are all the ones a hand edit or a half-finished write could produce.
@Suite("SessionState restoration")
struct SessionStateTests {

    private let frames: FrameIndex = 1_000_000
    private let rate: Double = 48_000

    private func restore(_ file: SessionFile) -> SessionRestoration {
        SessionState.restoring(file, frameCount: frames, sampleRate: rate)
    }

    private var wellFormed: SessionFile {
        SessionState(
            speed: SpeedState(ratio: 0.75, engine: .fast),
            loop: LoopRegion(range: FrameRange(start: 100, count: 5000), isEnabled: true),
            viewport: ViewportState(startFrame: 250, framesPerPixel: 64),
            playhead: 4242,
            track: TrackIdentity(sampleRate: rate, frameCount: frames)
        ).fileRepresentation
    }

    // MARK: - Round trip

    @Test("a well-formed payload restores exactly, with nothing repaired")
    func roundTripIsLossless() {
        let restored = restore(wellFormed)
        #expect(restored.repairs.isEmpty)
        #expect(restored.state.speed == SpeedState(ratio: 0.75, engine: .fast))
        #expect(restored.state.loop.range == FrameRange(start: 100, count: 5000))
        #expect(restored.state.loop.isEnabled)
        #expect(restored.state.viewport == ViewportState(startFrame: 250, framesPerPixel: 64))
        #expect(restored.state.playhead == 4242)
    }

    @Test("the state a model would capture survives a file round trip")
    func stateRoundTripsThroughItsFileRepresentation() {
        let state = SessionState(
            speed: SpeedState(ratio: 1.35, engine: .studio),
            loop: LoopRegion(range: FrameRange(start: 9, count: 11), isEnabled: false),
            viewport: ViewportState(startFrame: 3, framesPerPixel: 0.5),
            playhead: 7,
            track: TrackIdentity(sampleRate: rate, frameCount: frames))
        let restored = SessionState.restoring(
            state.fileRepresentation, frameCount: frames, sampleRate: rate)
        #expect(restored.state == state)
        #expect(restored.repairs.isEmpty)
    }

    // MARK: - Missing keys

    @Test("an empty payload degrades to defaults and reports every field")
    func emptyPayloadDegradesToDefaults() {
        let restored = restore(SessionFile())
        #expect(restored.state.speed == SpeedState())
        #expect(restored.state.loop == LoopRegion())
        #expect(restored.state.viewport == ViewportState.fitted)
        #expect(restored.state.playhead == 0)
        // Never silently: spec §8. Every absent field is named.
        #expect(
            Set(restored.repairs) == [.schemaVersion, .speed, .loop, .viewport, .playhead])
    }

    @Test("a single missing field leaves the others alone")
    func oneMissingFieldIsIsolated() {
        var file = wellFormed
        file.loop = nil
        let restored = restore(file)
        #expect(restored.repairs == [.loop])
        #expect(restored.state.loop == LoopRegion())
        #expect(restored.state.playhead == 4242)
    }

    // MARK: - Out of range

    @Test("a loop past the end of the recording is clamped, not trusted")
    func loopBeyondTheFileIsClamped() {
        var file = wellFormed
        file.loop = LoopRegion(
            range: FrameRange(start: frames - 10, count: frames), isEnabled: true)
        let restored = restore(file)
        #expect(restored.state.loop.range.end <= frames)
        #expect(restored.state.loop.range.start == frames - 10)
        #expect(restored.repairs.contains(.loop))
    }

    @Test("a negative loop collapses to empty rather than inverting")
    func negativeLoopCollapses() {
        var file = wellFormed
        file.loop = LoopRegion(range: FrameRange(start: -50, count: -900), isEnabled: true)
        let restored = restore(file)
        #expect(restored.state.loop.range.count >= 0)
        #expect(restored.state.loop.range.start >= 0)
        #expect(!restored.state.loop.isActive)
        #expect(restored.repairs.contains(.loop))
    }

    @Test("a playhead outside the recording is clamped to it")
    func playheadIsClamped() {
        for candidate: FrameIndex in [-1, FrameIndex.min, frames + 1, FrameIndex.max] {
            var file = wellFormed
            file.playhead = candidate
            let restored = restore(file)
            #expect(restored.state.playhead >= 0)
            #expect(restored.state.playhead <= frames)
            #expect(restored.repairs.contains(.playhead))
        }
    }

    @Test("a non-finite or negative zoom falls back to whole-file and says so")
    func nonsenseZoomFallsBackToFit() {
        for candidate in [Double.nan, .infinity, -.infinity, -12] {
            var file = wellFormed
            file.viewport = ViewportState(startFrame: 0, framesPerPixel: candidate)
            let restored = restore(file)
            #expect(restored.state.viewport == ViewportState.fitted)
            #expect(restored.repairs.contains(.viewport))
        }
    }

    /// Zero is the documented "whole file" sentinel, not damage — it is what
    /// `ViewportState.fitted` is — so it restores silently.
    @Test("a zero zoom is the fitted sentinel, not a repair")
    func zeroZoomIsTheFittedSentinel() {
        var file = wellFormed
        file.viewport = ViewportState(startFrame: 0, framesPerPixel: 0)
        let restored = restore(file)
        #expect(restored.state.viewport == ViewportState.fitted)
        #expect(!restored.repairs.contains(.viewport))
    }

    @Test("a viewport start outside the recording is clamped")
    func viewportStartIsClamped() {
        var file = wellFormed
        file.viewport = ViewportState(startFrame: -5, framesPerPixel: 32)
        #expect(restore(file).state.viewport.startFrame == 0)
        #expect(restore(file).repairs.contains(.viewport))

        file.viewport = ViewportState(startFrame: frames * 4, framesPerPixel: 32)
        #expect(restore(file).state.viewport.startFrame == frames)
    }

    @Test("speed keeps SpeedState's own clamp — a zero ratio never reaches the engine")
    func speedRatioCannotBeZero() {
        var file = wellFormed
        file.speed = SpeedState(ratio: 0)
        let restored = restore(file)
        #expect(restored.state.speed.ratio == SpeedState.minRatio)
        #expect(restored.state.speed.timeRatio.isFinite)
    }

    /// The specific crash a hand-edited sidecar could reach before `end`
    /// saturated: `start + count` overflowing `Int64` inside `clamped(to:)`.
    @Test("an Int64-overflowing loop clamps instead of trapping")
    func overflowingLoopDoesNotTrap() {
        var file = wellFormed
        file.loop = LoopRegion(
            range: FrameRange(start: .max, count: .max), isEnabled: true)
        let restored = restore(file)
        #expect(restored.state.loop.range.count == 0)
        #expect(restored.state.loop.range.end <= frames)
        #expect(restored.repairs.contains(.loop))
    }

    // MARK: - Identity

    @Test("a sidecar written for a different-length recording is flagged")
    func lengthMismatchIsFlagged() {
        var file = wellFormed
        file.track = TrackIdentity(sampleRate: rate, frameCount: frames * 2)
        #expect(restore(file).repairs.contains(.trackIdentity))
    }

    @Test("a sidecar written at a different sample rate is flagged")
    func sampleRateMismatchIsFlagged() {
        var file = wellFormed
        file.track = TrackIdentity(sampleRate: 44_100, frameCount: frames)
        #expect(restore(file).repairs.contains(.trackIdentity))
    }

    @Test("an unrecognised schema version is reported but does not discard the file")
    func futureSchemaIsReportedNotDiscarded() {
        var file = wellFormed
        file.schemaVersion = SessionFile.currentSchemaVersion + 99
        let restored = restore(file)
        #expect(restored.repairs == [.schemaVersion])
        #expect(restored.state.loop.range == FrameRange(start: 100, count: 5000))
    }

    // MARK: - Degenerate track

    @Test("restoring against an empty recording produces an empty, harmless state")
    func emptyTrackCollapsesEverything() {
        let restored = SessionState.restoring(wellFormed, frameCount: 0, sampleRate: rate)
        #expect(restored.state.playhead == 0)
        #expect(restored.state.loop.range.isEmpty)
        #expect(restored.state.viewport.startFrame == 0)
    }

    @Test("a negative frame count is treated as an empty recording")
    func negativeTrackLengthIsTreatedAsEmpty() {
        let restored = SessionState.restoring(wellFormed, frameCount: -10, sampleRate: rate)
        #expect(restored.state.playhead == 0)
        #expect(restored.state.loop.range.isEmpty)
    }

    // MARK: - Applying a viewport

    @Test("a restored viewport lands on the real Viewport, clamped by its own rules")
    func viewportRestoreClampsThroughViewport() {
        var viewport = Viewport(totalFrames: frames, widthPixels: 1000)
        viewport.restore(ViewportState(startFrame: 500, framesPerPixel: 16))
        #expect(viewport.framesPerPixel == 16)
        #expect(viewport.startFrame == 500)

        // Coarser than whole-file is impossible; it fits instead of overshooting.
        viewport.restore(ViewportState(startFrame: 0, framesPerPixel: 1e12))
        #expect(viewport.framesPerPixel == viewport.maxFramesPerPixel)

        // Finer than the hard limit is impossible too.
        viewport.restore(ViewportState(startFrame: 0, framesPerPixel: 1e-30))
        #expect(viewport.framesPerPixel == Viewport.minFramesPerPixel)
    }

    @Test("the fitted sentinel restores the whole file")
    func fittedSentinelFits() {
        var viewport = Viewport(totalFrames: frames, widthPixels: 1000)
        viewport.zoom(by: 64, anchorFrame: 0)
        viewport.restore(.fitted)
        #expect(viewport.framesPerPixel == viewport.maxFramesPerPixel)
        #expect(viewport.startFrame == 0)
    }

    @Test("a viewport captured from a Viewport restores it")
    func viewportCaptureRoundTrips() {
        var viewport = Viewport(totalFrames: frames, widthPixels: 1000)
        viewport.zoom(by: 8, anchorFrame: 400_000)
        let captured = viewport.state
        var other = Viewport(totalFrames: frames, widthPixels: 1000)
        other.restore(captured)
        #expect(other.startFrame == viewport.startFrame)
        #expect(other.framesPerPixel == viewport.framesPerPixel)
    }
}
