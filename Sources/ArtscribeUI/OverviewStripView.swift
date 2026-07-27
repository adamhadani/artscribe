import ArtscribeKit
import SwiftUI

/// The whole file at constant scale, with the visible window drawn as a lens:
/// everything outside it is veiled, and the window itself carries accent edges.
/// Dragging anywhere on the strip moves the window there.
struct OverviewStripView: View {
    let model: ViewerModel
    @Environment(\.displayScale) private var displayScale
    @State private var overviewWidth: Double = 1

    var body: some View {
        ZStack(alignment: .topLeading) {
            Palette.panel.color()

            if let image = model.overviewImage {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .interpolation(.none)
                    .opacity(0.75)
            }

            Canvas(rendersAsynchronously: false) { context, size in
                drawWindow(in: &context, size: size)
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

    private func drawWindow(in context: inout GraphicsContext, size: CGSize) {
        guard model.hasTrack else { return }
        let total = model.totalFrames
        let left = PixelMapping.overviewPixel(
            forFrame: model.viewport.startFrame, totalFrames: total, width: size.width)
        let right = PixelMapping.overviewPixel(
            forFrame: model.viewport.endFrame, totalFrames: total, width: size.width)
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

        drawSelection(in: &context, size: size, total: total)
    }

    private func drawSelection(in context: inout GraphicsContext, size: CGSize, total: FrameIndex) {
        let range = model.selection.range
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
