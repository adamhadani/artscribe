import ArtscribeKit
import Testing

@testable import ArtscribeUI

@Suite("PixelMapping")
struct PixelMappingTests {

    private static let total: FrameIndex = 25_371_648

    private func fitted(width: Int = 1000) -> Viewport {
        Viewport(totalFrames: Self.total, widthPixels: width)
    }

    @Test("a drag maps to the frames under the two pixels")
    func dragMapsToFrames() {
        let viewport = fitted()
        let range = PixelMapping.range(fromPixel: 100, toPixel: 400, in: viewport)
        #expect(range.start == viewport.frame(atPixel: 100))
        #expect(range.end == viewport.frame(atPixel: 400))
        #expect(range.count > 0)
    }

    @Test("dragging right-to-left produces the same range as left-to-right")
    func dragIsDirectionless() {
        let viewport = fitted()
        let forward = PixelMapping.range(fromPixel: 120, toPixel: 640, in: viewport)
        let backward = PixelMapping.range(fromPixel: 640, toPixel: 120, in: viewport)
        #expect(forward == backward)
    }

    @Test("a drag that never moved is an empty range, not a one-frame one")
    func clickIsEmpty() {
        let range = PixelMapping.range(fromPixel: 300, toPixel: 300, in: fitted())
        #expect(range.isEmpty)
        #expect(range.count == 0)
    }

    /// `Viewport.frame(atPixel:)` clamps only to `Int64`; a selection must not be
    /// allowed to run off either end of the file.
    @Test("pixels outside the lane clamp to the file, not past it")
    func clampsToFile() {
        let viewport = fitted()
        #expect(PixelMapping.frame(atPixel: -5000, in: viewport) == 0)
        #expect(PixelMapping.frame(atPixel: 1e12, in: viewport) == Self.total)
        let range = PixelMapping.range(fromPixel: -1e9, toPixel: 1e9, in: viewport)
        #expect(range.start == 0)
        #expect(range.end == Self.total)
    }

    @Test("non-finite pixel positions do not escape the file")
    func nonFinite() {
        let viewport = fitted()
        #expect(PixelMapping.frame(atPixel: .nan, in: viewport) == 0)
        #expect(PixelMapping.frame(atPixel: .infinity, in: viewport) == Self.total)
        #expect(PixelMapping.frame(atPixel: -.infinity, in: viewport) == 0)
    }

    @Test("one pixel of drag covers one pixel worth of frames when zoomed in")
    func zoomedIn() {
        var viewport = fitted()
        viewport.zoom(by: 4000, anchorFrame: 10_000_000)
        let range = PixelMapping.range(fromPixel: 10, toPixel: 11, in: viewport)
        // Each edge rounds independently, so the span can differ by one frame.
        #expect(abs(Double(range.count) - viewport.framesPerPixel) <= 1)
    }

    @Test("overview positions round-trip through the strip width")
    func overviewRoundTrip() {
        let width = 900.0
        for frame in [FrameIndex(0), 1, Self.total / 3, Self.total] {
            let pixel = PixelMapping.overviewPixel(
                forFrame: frame, totalFrames: Self.total, width: width)
            #expect(pixel >= 0 && pixel <= width)
            let back = PixelMapping.overviewFrame(
                atPixel: pixel, totalFrames: Self.total, width: width)
            // One strip pixel is ~28 000 frames wide; round-tripping cannot beat that.
            #expect(abs(back - frame) <= FrameIndex(Double(Self.total) / width) + 1)
        }
    }

    @Test("an empty overview does not divide by zero")
    func emptyOverview() {
        #expect(PixelMapping.overviewPixel(forFrame: 5, totalFrames: 0, width: 100) == 0)
        #expect(PixelMapping.overviewFrame(atPixel: 50, totalFrames: 0, width: 100) == 0)
        #expect(PixelMapping.overviewFrame(atPixel: .nan, totalFrames: 100, width: 100) == 0)
    }

    @Test("overview clicks outside the strip clamp to its ends")
    func overviewClamps() {
        #expect(PixelMapping.overviewFrame(atPixel: -40, totalFrames: 1000, width: 100) == 0)
        #expect(PixelMapping.overviewFrame(atPixel: 400, totalFrames: 1000, width: 100) == 1000)
    }
}
