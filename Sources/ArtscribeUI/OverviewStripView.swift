import ArtscribeKit
import SwiftUI

/// The whole file at constant scale, with the visible window drawn as a lens:
/// everything outside it is veiled, and the window itself carries accent edges.
/// Dragging anywhere on the strip moves the window there.
struct OverviewStripView: View {
    let model: ViewerModel
    @Environment(\.displayScale) private var displayScale
    @State private var overviewWidth: Double = 1

    /// Everything the lens overlay needs, read once at body level and handed
    /// to the `Canvas` closure as one value.
    private struct OverlayState {
        let hasTrack: Bool
        let viewport: Viewport
        let totalFrames: FrameIndex
        let selectionRange: FrameRange
        let loop: LoopRegion
        let playhead: FrameIndex
    }

    var body: some View {
        // Read at body level: `overviewImage` is deliberately invariant under
        // pan/zoom, but the lens rectangle — the entire point of this strip —
        // is driven by `model.viewport`, which must be read somewhere SwiftUI
        // definitely tracks, not only inside the `Canvas` closure.
        let state = OverlayState(
            hasTrack: model.hasTrack,
            viewport: model.viewport,
            totalFrames: model.totalFrames,
            selectionRange: model.selection.range,
            loop: model.loop,
            playhead: model.playhead)

        ZStack(alignment: .topLeading) {
            Palette.panel.color()

            if let image = model.overviewImage {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .interpolation(.none)
                    .opacity(0.75)
            }

            Canvas(rendersAsynchronously: false) { context, size in
                drawWindow(in: &context, size: size, state: state)
            }
            .allowsHitTesting(false)
        }
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    model.centre(
                        on: PixelMapping.overviewFrame(
                            atPixel: value.location.x,
                            totalFrames: model.totalFrames,
                            width: overviewWidth))
                }
        )
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: { size in
            overviewWidth = size.width
            model.setOverviewSize(size)
        }
    }

    private func drawWindow(in context: inout GraphicsContext, size: CGSize, state: OverlayState) {
        guard state.hasTrack else { return }
        let left = PixelMapping.overviewPixel(
            forFrame: state.viewport.startFrame, totalFrames: state.totalFrames, width: size.width)
        let right = PixelMapping.overviewPixel(
            forFrame: state.viewport.endFrame, totalFrames: state.totalFrames, width: size.width)
        // A fully zoomed-out window would otherwise vanish into a hairline.
        let windowWidth = max(2.0, right - left)

        let veil = Palette.background.color(opacity: 0.62)
        context.fill(Path(CGRect(x: 0, y: 0, width: left, height: size.height)), with: .color(veil))
        context.fill(
            Path(
                CGRect(
                    x: left + windowWidth, y: 0,
                    width: max(0, size.width - left - windowWidth), height: size.height)),
            with: .color(veil))

        context.stroke(
            Path(CGRect(x: left, y: 0.5, width: windowWidth, height: size.height - 1)),
            with: .color(Palette.accent.color(opacity: 0.9)),
            lineWidth: 1)

        drawSelection(
            in: &context, size: size, total: state.totalFrames, range: state.selectionRange)
        drawLoop(in: &context, size: size, total: state.totalFrames, loop: state.loop)
        drawPlayhead(in: &context, size: size, total: state.totalFrames, frame: state.playhead)
    }

    /// The loop, so that a region set while zoomed in is still findable after you
    /// zoom back out to the whole file.
    private func drawLoop(
        in context: inout GraphicsContext, size: CGSize, total: FrameIndex, loop: LoopRegion
    ) {
        guard !loop.range.isEmpty else { return }
        let left = PixelMapping.overviewPixel(
            forFrame: loop.range.start, totalFrames: total, width: size.width)
        let right = PixelMapping.overviewPixel(
            forFrame: loop.range.end, totalFrames: total, width: size.width)
        let opacity = loop.isEnabled ? 1.0 : Palette.loopDisabledOpacity
        context.fill(
            Path(CGRect(x: left, y: 0, width: max(1, right - left), height: 3)),
            with: .color(Palette.loop.color(opacity: opacity)))
    }

    private func drawPlayhead(
        in context: inout GraphicsContext, size: CGSize, total: FrameIndex, frame: FrameIndex
    ) {
        let x = PixelMapping.overviewPixel(forFrame: frame, totalFrames: total, width: size.width)
        context.fill(
            Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)),
            with: .color(Palette.accent.color()))
    }

    private func drawSelection(
        in context: inout GraphicsContext, size: CGSize, total: FrameIndex, range: FrameRange
    ) {
        guard !range.isEmpty else { return }
        let left = PixelMapping.overviewPixel(
            forFrame: range.start, totalFrames: total, width: size.width)
        let right = PixelMapping.overviewPixel(
            forFrame: range.end, totalFrames: total, width: size.width)
        context.fill(
            Path(CGRect(x: left, y: 0, width: max(1, right - left), height: size.height)),
            with: .color(Palette.selection.color(opacity: 0.22)))
    }
}
