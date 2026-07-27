import AppKit
import ArtscribeKit
import SwiftUI

/// The main timeline: the cached waveform bitmap with live overlays on top.
///
/// Nothing here recomputes peaks. The bitmap comes from `ViewerModel`, which
/// regenerates it only when the viewport or the lane size changes; the selection
/// band, channel rules and playhead are drawn every frame because they are a
/// handful of rectangles.
struct WaveformLanesView: View {
    let model: ViewerModel
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack(alignment: .topLeading) {
            Palette.panel.color()

            if let image = model.waveformImage {
                // The bitmap is produced at `displayScale`, so this maps one
                // image pixel to one screen pixel and needs no smoothing.
                // `.resizable()` only matters for the frame between a live
                // resize and the redraw that follows it.
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .interpolation(.none)
            }

            Canvas(rendersAsynchronously: false) { context, size in
                draw(in: &context, size: size)
            }
            .allowsHitTesting(false)
        }
        .contentShape(.rect)
        .gesture(dragGesture)
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: { size in
            model.setLaneSize(size, scale: displayScale)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                model.dragChanged(
                    startPixel: value.startLocation.x,
                    currentPixel: value.location.x,
                    extending: NSEvent.modifierFlags.contains(.shift))
            }
            .onEnded { value in
                model.dragEnded(
                    startPixel: value.startLocation.x,
                    endPixel: value.location.x,
                    now: ProcessInfo.processInfo.systemUptime)
            }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        drawChannelRules(in: &context, size: size)
        drawSelection(in: &context, size: size)
        drawPlayhead(in: &context, size: size)
        drawChannelLabels(in: &context, size: size)
    }

    private func drawChannelRules(in context: inout GraphicsContext, size: CGSize) {
        guard model.channels > 1 else { return }
        let laneHeight = size.height / Double(model.channels)
        for lane in 1..<model.channels {
            let y = laneHeight * Double(lane)
            context.fill(
                Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                with: .color(Palette.background.color(opacity: 0.8)))
        }
    }

    private func drawSelection(in context: inout GraphicsContext, size: CGSize) {
        let range = model.selection.range
        guard !range.isEmpty else { return }
        let startX = model.viewport.pixel(forFrame: range.start)
        let endX = model.viewport.pixel(forFrame: range.end)
        guard endX > 0, startX < size.width else { return }

        let left = max(0, startX)
        let right = min(size.width, endX)
        context.fill(
            Path(CGRect(x: left, y: 0, width: max(0, right - left), height: size.height)),
            with: .color(Palette.selection.color(opacity: Palette.selectionFillOpacity)))

        let edge = Palette.selectionEdgeWidth
        for x in [startX, endX] where x >= -edge && x <= size.width + edge {
            context.fill(
                Path(CGRect(x: x - edge / 2, y: 0, width: edge, height: size.height)),
                with: .color(Palette.selection.color()))
        }
    }

    /// The zoom anchor. Drawn so it is obvious what `E`/`R` pivot around.
    private func drawPlayhead(in context: inout GraphicsContext, size: CGSize) {
        guard model.hasTrack, model.selection.isEmpty else { return }
        let x = model.viewport.pixel(forFrame: model.playhead)
        guard x >= 0, x <= size.width else { return }
        context.fill(
            Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)),
            with: .color(Palette.accent.color(opacity: 0.9)))
    }

    private func drawChannelLabels(in context: inout GraphicsContext, size: CGSize) {
        guard model.channels > 0 else { return }
        let laneHeight = size.height / Double(model.channels)
        for lane in 0..<model.channels {
            let text = Text(Self.channelLabel(lane, of: model.channels))
                .font(Typography.laneLabel)
                .foregroundStyle(Palette.dimmed.color())
            context.draw(
                text, at: CGPoint(x: 8, y: laneHeight * Double(lane) + 10), anchor: .leading)
        }
    }

    static func channelLabel(_ index: Int, of total: Int) -> String {
        guard total == 2 else { return "CH\(index + 1)" }
        return index == 0 ? "L" : "R"
    }
}
