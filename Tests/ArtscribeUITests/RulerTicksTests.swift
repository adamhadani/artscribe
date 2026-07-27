import ArtscribeKit
import Testing

@testable import ArtscribeUI

@Suite("RulerTicks")
struct RulerTicksTests {

    private static let rate = 44100.0
    /// The reference track: 9:35 at 44.1 kHz.
    private static let total: FrameIndex = 25_371_648

    private func viewport(width: Int, framesPerPixel: Double) -> Viewport {
        var viewport = Viewport(totalFrames: Self.total, widthPixels: width)
        // `zoom(by:)` is relative, so derive the factor from the fitted state.
        viewport.zoom(by: viewport.framesPerPixel / framesPerPixel, anchorFrame: 0)
        return viewport
    }

    @Test("the chosen interval always spaces labels at least minSpacing apart")
    func spacingHolds() {
        let candidates = [0.02, 0.5, 5.0, 50.0, 500.0, 5000.0, 50_000.0]
        for framesPerPixel in candidates {
            let secondsPerPixel = framesPerPixel / Self.rate
            let (interval, divisions) = RulerTicks.majorInterval(
                secondsPerPixel: secondsPerPixel, minSpacing: 84)
            // The coarsest ladder entry is allowed to fall short; nothing else is.
            if interval < 3600 {
                #expect(interval / secondsPerPixel >= 84)
            }
            #expect(divisions >= 2)
        }
    }

    @Test("the interval is the smallest one that fits, not merely one that fits")
    func intervalIsTight() {
        // 1 s/px: a 60 s major tick is 60 px, too tight for 84 px, so 120 s wins.
        #expect(RulerTicks.majorInterval(secondsPerPixel: 1, minSpacing: 84).interval == 120)
        // 0.001 s/px: 0.1 s is 100 px, and 0.05 s would only be 50 px.
        #expect(RulerTicks.majorInterval(secondsPerPixel: 0.001, minSpacing: 84).interval == 0.1)
    }

    @Test("degenerate zoom levels fall back rather than trapping")
    func degenerate() {
        #expect(RulerTicks.majorInterval(secondsPerPixel: 0, minSpacing: 84).interval == 0.001)
        #expect(RulerTicks.majorInterval(secondsPerPixel: .nan, minSpacing: 84).interval == 0.001)
        #expect(RulerTicks.majorInterval(secondsPerPixel: 1e12, minSpacing: 84).interval == 3600)
    }

    @Test("ticks stay inside the viewport and stay ordered")
    func ticksInRange() {
        let viewport = viewport(width: 1200, framesPerPixel: 500)
        let ticks = RulerTicks.ticks(viewport: viewport, sampleRate: Self.rate)
        #expect(!ticks.isEmpty)
        var previous: FrameIndex = -1
        for tick in ticks {
            #expect(tick.frame >= viewport.startFrame)
            #expect(tick.frame <= viewport.endFrame)
            #expect(tick.frame > previous)
            previous = tick.frame
        }
    }

    @Test("only major ticks carry labels, and labels gain milliseconds when zoomed in")
    func labelling() {
        let wide = RulerTicks.ticks(
            viewport: viewport(width: 1200, framesPerPixel: 20_000), sampleRate: Self.rate)
        let close = RulerTicks.ticks(
            viewport: viewport(width: 1200, framesPerPixel: 5), sampleRate: Self.rate)

        #expect(wide.contains { $0.isMajor })
        #expect(wide.allSatisfy { $0.isMajor == ($0.label != nil) })
        #expect(close.allSatisfy { $0.isMajor == ($0.label != nil) })

        let wideLabel = wide.first { $0.label != nil }?.label
        let closeLabel = close.first { $0.label != nil }?.label
        #expect(wideLabel?.contains(".") == false)
        #expect(closeLabel?.contains(".") == true)
    }

    @Test("the tick count stays bounded across the whole zoom range")
    func boundedCount() {
        for framesPerPixel in [0.01, 1.0, 100.0, 10_000.0, 100_000.0] {
            let ticks = RulerTicks.ticks(
                viewport: viewport(width: 1600, framesPerPixel: framesPerPixel),
                sampleRate: Self.rate)
            #expect(ticks.count < 200)
        }
    }

    @Test("no ticks without a usable sample rate or a file")
    func noTrack() {
        let viewport = viewport(width: 800, framesPerPixel: 100)
        #expect(RulerTicks.ticks(viewport: viewport, sampleRate: 0).isEmpty)
        #expect(
            RulerTicks.ticks(
                viewport: Viewport(totalFrames: 0, widthPixels: 800), sampleRate: Self.rate
            ).isEmpty)
    }
}
