import Testing

@testable import ArtscribeKit

private func makeViewport() -> Viewport {
    Viewport(totalFrames: 1_000_000, widthPixels: 1000)  // fit => 1000 frames/pixel
}

@Test func fitShowsWholeFile() {
    var v = makeViewport()
    v.fit()
    #expect(v.startFrame == 0)
    #expect(v.framesPerPixel == 1000)
    #expect(v.endFrame == 1_000_000)
}

@Test func zoomKeepsAnchorFrameUnderTheSamePixel() {
    var v = makeViewport()
    v.fit()
    let anchor: FrameIndex = 400_000
    let pixelBefore = v.pixel(forFrame: anchor)
    v.zoom(by: 4.0, anchorFrame: anchor)
    let pixelAfter = v.pixel(forFrame: anchor)
    #expect(abs(pixelBefore - pixelAfter) < 0.5)
    #expect(v.framesPerPixel == 250)
}

@Test func zoomOutClampsToFit() {
    var v = makeViewport()
    v.fit()
    v.zoom(by: 0.01, anchorFrame: 500_000)  // try to zoom way out
    #expect(v.framesPerPixel == 1000)  // never coarser than fit
    #expect(v.startFrame == 0)
}

@Test func zoomInClampsAtMaximum() {
    var v = makeViewport()
    v.fit()
    for _ in 0..<50 { v.zoom(by: 4.0, anchorFrame: 500_000) }
    #expect(v.framesPerPixel >= Viewport.minFramesPerPixel)
    #expect(v.framesPerPixel == Viewport.minFramesPerPixel)
}

@Test func scrollClampsAtBothEnds() {
    var v = makeViewport()
    v.fit()
    v.zoom(by: 10.0, anchorFrame: 0)  // 100 frames/pixel, 100_000 visible
    v.scroll(byPixels: -10_000)
    #expect(v.startFrame == 0)
    v.scroll(byPixels: 1_000_000)
    #expect(v.endFrame == 1_000_000)
    #expect(v.startFrame == 1_000_000 - v.visibleFrames)
}

@Test func zoomToRangeFramesTheRange() {
    var v = makeViewport()
    v.zoom(to: FrameRange(start: 200_000, count: 100_000))
    #expect(v.startFrame == 200_000)
    #expect(v.visibleFrames == 100_000)
}

@Test func pixelAndFrameRoundTrip() {
    var v = makeViewport()
    v.fit()
    v.zoom(by: 8.0, anchorFrame: 500_000)
    let f: FrameIndex = 500_000
    #expect(v.frame(atPixel: v.pixel(forFrame: f)) == f)
}

@Test func frameRangeClampsToBounds() {
    let r = FrameRange(start: -50, count: 200).clamped(to: 100)
    #expect(r.start == 0)
    #expect(r.end == 100)
}

// MARK: - Finding 1: resize(widthPixels:) must reclamp framesPerPixel, not just startFrame.

@Test func resizeNeverExceedsFitInvariant() {
    var v = Viewport(totalFrames: 1_000_000, widthPixels: 100)
    #expect(v.framesPerPixel == 10_000)
    v.resize(widthPixels: 100_000)
    #expect(v.framesPerPixel == v.maxFramesPerPixel)
    #expect(v.framesPerPixel == 10)
    #expect(v.endFrame <= v.totalFrames)
}

// MARK: - Finding 2: very short (including empty) files must never overshoot totalFrames.

@Test func emptyFileDegeneratesSanely() {
    let v = Viewport(totalFrames: 0, widthPixels: 1000)
    #expect(v.startFrame == 0)
    #expect(v.endFrame == 0)
    #expect(v.visibleFrames == 0)
}

@Test func singleFrameFileNeverOvershootsTotalFrames() {
    let v = Viewport(totalFrames: 1, widthPixels: 1000)
    #expect(v.visibleFrames <= v.totalFrames)
    #expect(v.endFrame <= v.totalFrames)
}

@Test func fileShorterThanWidthNeverOvershootsTotalFrames() {
    let v = Viewport(totalFrames: 9, widthPixels: 1000)
    #expect(v.visibleFrames <= v.totalFrames)
    #expect(v.endFrame <= v.totalFrames)
}

// MARK: - Finding 3: extreme Double -> FrameIndex conversions must clamp, not trap.

@Test func scrollByExtremePixelCountClampsRatherThanCrashing() {
    var v = makeViewport()
    v.fit()
    v.scroll(byPixels: Int.max)
    #expect(v.endFrame == v.totalFrames)
    #expect(v.startFrame >= 0)
}

@Test func frameAtExtremePixelClampsRatherThanCrashing() {
    var v = makeViewport()
    v.fit()
    // `frame(atPixel:)` is a pure coordinate conversion (not bounded by totalFrames —
    // a pixel past the visible edge legitimately maps past endFrame); the invariant
    // under test is that an absurd pixel clamps into FrameIndex's range instead of
    // trapping on the Double -> Int64 conversion.
    let f = v.frame(atPixel: 1e300)
    #expect(f == FrameIndex.max)
}

@Test func zoomWithExtremeAnchorAndZoomOutClampsRatherThanCrashing() {
    var v = makeViewport()
    v.fit()
    // Zoom in repeatedly to reach the floor (framesPerPixel == minFramesPerPixel).
    for _ in 0..<50 { v.zoom(by: 4.0, anchorFrame: 500_000) }
    // Zoom out drastically anchored on an extreme frame far from startFrame: the
    // anchor-preserving arithmetic must not overflow Int64 during the conversion.
    v.zoom(by: 0.0001, anchorFrame: FrameIndex.max)
    #expect(v.startFrame >= 0)
    #expect(v.endFrame <= v.totalFrames)
}
