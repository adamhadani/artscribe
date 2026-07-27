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
