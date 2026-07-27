import ArtscribeKit
import AudioDecode
import CoreGraphics
import Waveform

/// Rasterises waveform lanes into a bitmap once per viewport change.
///
/// The lanes are the only expensive thing on screen, so they are drawn into a
/// `CGImage` that the view simply blits. Selection, playhead and ruler overlays
/// draw on top every frame, which is cheap. `Key` is what the model compares to
/// decide whether the existing image is still valid — if nothing in it moved,
/// nothing is redrawn.
///
/// Columns are written straight into the bitmap's backing store rather than
/// through `CGContext` drawing calls. That is not premature cleverness: filling
/// ~2 500 one-pixel-wide rectangles cost 80–170 ms per redraw on the reference
/// track, whether issued as `fill(rects)`, as one path, or with antialiasing
/// off, and the cost tracked the rectangle *count* rather than the bitmap area
/// — the 2040x116 overview strip was as slow as the full-height lanes. A
/// waveform column is an axis-aligned run of identical pixels, so there is
/// nothing here for a rasteriser to do that a loop cannot do faster.
enum WaveformRenderer {

    struct Key: Equatable {
        var generation: Int
        var startFrame: FrameIndex
        var framesPerPixel: Double
        var visibleFrames: FrameIndex
        var pixelWidth: Int
        var pixelHeight: Int
    }

    /// Vertical breathing room inside each lane, in bitmap pixels per side.
    private static let laneInset: Double = 3

    /// One drawn column: the extremes of everything that falls under it.
    private struct Column {
        var min: Float
        var max: Float
    }

    /// Draws `range` as one stacked lane per channel.
    ///
    /// `pixelWidth`/`pixelHeight` are backing-store pixels, so peaks are computed
    /// at full Retina resolution and the image maps 1:1 onto the display.
    ///
    /// Below the pyramid's base bucket the columns come from `audio` directly:
    /// the pyramid cannot resolve finer than 256 frames, so zooming past that
    /// against it alone turns a waveform into a staircase of 256-frame blocks
    /// instead of showing individual cycles.
    static func render(
        audio: DecodedAudio,
        pyramid: PeakPyramid,
        range: FrameRange,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> CGImage? {
        guard pixelWidth > 0, pixelHeight > 0, pyramid.channels > 0 else { return nil }
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
            let base = context.data
        else { return nil }

        // `bytesPerRow` may be padded for alignment, so stride in words rather
        // than assuming it equals `pixelWidth`.
        let stride = context.bytesPerRow / 4
        let pixels = base.bindMemory(to: UInt32.self, capacity: stride * pixelHeight)
        let colour = packed(Palette.waveform)
        let laneHeight = Double(pixelHeight) / Double(pyramid.channels)
        let half = Swift.max(1, laneHeight / 2 - laneInset)

        let framesPerPixel = Double(range.count) / Double(pixelWidth)
        let fromSamples = framesPerPixel < Double(PeakPyramid.baseBucketFrames)

        for channel in 0..<pyramid.channels {
            let columns =
                fromSamples
                ? sampleColumns(audio: audio, channel: channel, range: range, count: pixelWidth)
                : pyramidColumns(
                    pyramid: pyramid, channel: channel, range: range, count: pixelWidth)
            guard columns.count == pixelWidth else { continue }
            // Row 0 is the top of the bitmap, so channel 0 lands at the top and
            // a positive sample reaches towards a smaller row index.
            let mid = Double(channel) * laneHeight + laneHeight / 2

            for x in 0..<pixelWidth {
                let lo = Double(Swift.max(-1, Swift.min(1, columns[x].min)))
                let hi = Double(Swift.max(-1, Swift.min(1, columns[x].max)))
                var top = Int((mid - hi * half).rounded(.down))
                // Silence has lo == hi == 0; the one-pixel floor keeps it a
                // continuous centre line rather than a gap in the waveform.
                var bottom = Swift.max(top + 1, Int((mid - lo * half).rounded(.up)))
                top = Swift.max(0, Swift.min(pixelHeight - 1, top))
                bottom = Swift.max(top + 1, Swift.min(pixelHeight, bottom))
                var offset = top * stride + x
                for _ in top..<bottom {
                    pixels[offset] = colour
                    offset += stride
                }
            }
        }
        return context.makeImage()
    }

    private static func pyramidColumns(
        pyramid: PeakPyramid,
        channel: Int,
        range: FrameRange,
        count: Int
    ) -> [Column] {
        pyramid.peaks(channel: channel, range: range, buckets: count)
            .map { Column(min: $0.min, max: $0.max) }
    }

    /// Per-column extremes read straight from the decoded samples.
    ///
    /// Each column reaches one sample into the next so neighbours join up: past
    /// one frame per pixel a column otherwise covers a single sample and the
    /// trace breaks into disconnected dots instead of a waveform.
    private static func sampleColumns(
        audio: DecodedAudio,
        channel: Int,
        range: FrameRange,
        count: Int
    ) -> [Column] {
        var columns = [Column](repeating: Column(min: 0, max: 0), count: count)
        let clamped = range.clamped(to: audio.frameCount)
        guard count > 0, channel < audio.channels, !clamped.isEmpty, audio.frameCount > 0 else {
            return columns
        }
        let samples = audio.channel(channel)
        let framesPerColumn = Double(clamped.count) / Double(count)
        let lastFrame = audio.frameCount - 1

        for index in 0..<count {
            let first = clamped.start + FrameIndex(Double(index) * framesPerColumn)
            let next =
                clamped.start + FrameIndex((Double(index + 1) * framesPerColumn).rounded(.up))
            let lo = Swift.max(0, Swift.min(lastFrame, first))
            let hi = Swift.max(lo, Swift.min(lastFrame, next))
            var minimum = Float.greatestFiniteMagnitude
            var maximum = -Float.greatestFiniteMagnitude
            for frame in lo...hi {
                let value = samples[Int(frame)]
                minimum = Swift.min(minimum, value)
                maximum = Swift.max(maximum, value)
            }
            columns[index] = Column(min: minimum, max: maximum)
        }
        return columns
    }

    /// One opaque pixel in the context's premultiplied little-endian BGRA
    /// layout, which reads as `0xAARRGGBB` in a host-order word.
    private static func packed(_ rgb: RGB) -> UInt32 {
        func component(_ value: Double) -> UInt32 {
            UInt32(Swift.max(0, Swift.min(255, (value * 255).rounded())))
        }
        return 0xFF00_0000 | (component(rgb.red) << 16) | (component(rgb.green) << 8)
            | component(rgb.blue)
    }
}
