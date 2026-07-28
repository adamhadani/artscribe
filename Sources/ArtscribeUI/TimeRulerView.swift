import ArtscribeKit
import SwiftUI

/// The time ruler above the lanes. Tick spacing comes from `RulerTicks`, which is
/// pure and tested; this view only paints what it is given.
struct TimeRulerView: View {
    let model: ViewerModel
    @Environment(\.palette) private var palette

    private static let majorTickHeight: Double = 9
    private static let minorTickHeight: Double = 4

    var body: some View {
        // Read at body level, not inside the `Canvas` closure: SwiftUI's
        // `@Observable` tracking is only guaranteed where `body` itself reads
        // the property. This view's body previously read nothing from `model`
        // at all, so panning or zooming risked leaving the ruler frozen.
        let hasTrack = model.hasTrack
        let viewport = model.viewport
        let sampleRate = model.sampleRate
        let selectionRange = model.selection.range
        let loop = model.loop
        let playhead = model.playhead

        Canvas(rendersAsynchronously: false) { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(palette.background.color()))
            context.fill(
                Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)),
                with: .color(palette.rule.color()))
            guard hasTrack else { return }

            for tick in RulerTicks.ticks(viewport: viewport, sampleRate: sampleRate) {
                let x = viewport.pixel(forFrame: tick.frame).rounded()
                guard x >= 0, x <= size.width else { continue }
                let height = tick.isMajor ? Self.majorTickHeight : Self.minorTickHeight
                context.fill(
                    Path(CGRect(x: x, y: size.height - height - 1, width: 1, height: height)),
                    with: .color(
                        tick.isMajor
                            ? palette.dimmed.color()
                            : palette.dimmed.color(opacity: 0.45)))

                if let label = tick.label, x + 44 < size.width {
                    context.draw(
                        Text(label)
                            .font(Typography.tick)
                            .foregroundStyle(palette.dimmed.color()),
                        at: CGPoint(x: x + 4, y: 8),
                        anchor: .leading)
                }
            }

            drawLoopMarkers(in: &context, size: size, loop: loop, viewport: viewport)
            drawSelectionMarkers(
                in: &context, size: size, range: selectionRange, viewport: viewport)
            drawPlayhead(in: &context, size: size, frame: playhead, viewport: viewport)
        }
        .frame(height: 24)
        .contentShape(.rect)
        .gesture(zoomDragGesture)
    }

    /// Drag vertically to zoom, smoothly, anchored where the drag began — the
    /// beat-time ruler convention Ableton Live and Melodyne both document, and
    /// the only continuous zoom control the app has that needs no modifier and
    /// no trackpad. Horizontal travel is ignored; see
    /// `ViewerModel.zoomDragChanged`.
    ///
    /// `coordinateSpace: .local` puts `x` in the ruler's own points, which is
    /// the space the viewport maps from — the ruler and the lanes are siblings
    /// in the same full-width `VStack`, so a point means the same thing in
    /// both, and both draw through `viewport.pixel(forFrame:)`.
    private var zoomDragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { model.zoomDragChanged(start: $0.startLocation, current: $0.location) }
            .onEnded { _ in model.zoomDragEnded() }
    }

    /// The loop shown as a bar spanning the region, so the in and out points stay
    /// findable when the lanes are busy — the same job the selection markers do.
    private func drawLoopMarkers(
        in context: inout GraphicsContext, size: CGSize, loop: LoopRegion, viewport: Viewport
    ) {
        guard !loop.range.isEmpty else { return }
        let startX = viewport.pixel(forFrame: loop.range.start)
        let endX = viewport.pixel(forFrame: loop.range.end)
        guard endX > 0, startX < size.width else { return }
        let opacity = loop.isEnabled ? 1.0 : Palette.loopDisabledOpacity
        let left = max(0, startX)
        let width = max(1, min(size.width, endX) - left)
        context.fill(
            Path(CGRect(x: left, y: 0, width: width, height: 3)),
            with: .color(palette.loop.color(opacity: opacity)))
    }

    /// The playhead marker. Drawn last so it is never hidden under a loop bar or
    /// a selection post.
    private func drawPlayhead(
        in context: inout GraphicsContext, size: CGSize, frame: FrameIndex, viewport: Viewport
    ) {
        let x = viewport.pixel(forFrame: frame)
        guard x >= 0, x <= size.width else { return }
        context.fill(
            Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)),
            with: .color(palette.accent.color()))
    }

    /// The selection edges repeat on the ruler so the in/out points stay findable
    /// when the lanes are busy.
    private func drawSelectionMarkers(
        in context: inout GraphicsContext, size: CGSize, range: FrameRange, viewport: Viewport
    ) {
        guard !range.isEmpty else { return }
        for frame in [range.start, range.end] {
            let x = viewport.pixel(forFrame: frame)
            guard x >= 0, x <= size.width else { continue }
            context.fill(
                Path(CGRect(x: x - 1, y: size.height - 5, width: 2, height: 5)),
                with: .color(palette.selection.color()))
        }
    }
}
