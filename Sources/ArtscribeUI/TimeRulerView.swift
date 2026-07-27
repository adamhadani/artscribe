import ArtscribeKit
import SwiftUI

/// The time ruler above the lanes. Tick spacing comes from `RulerTicks`, which is
/// pure and tested; this view only paints what it is given.
struct TimeRulerView: View {
    let model: ViewerModel

    private static let majorTickHeight: Double = 9
    private static let minorTickHeight: Double = 4

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Palette.background.color()))
            context.fill(
                Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)),
                with: .color(Palette.rule.color()))
            guard model.hasTrack else { return }

            for tick in RulerTicks.ticks(viewport: model.viewport, sampleRate: model.sampleRate) {
                let x = model.viewport.pixel(forFrame: tick.frame).rounded()
                guard x >= 0, x <= size.width else { continue }
                let height = tick.isMajor ? Self.majorTickHeight : Self.minorTickHeight
                context.fill(
                    Path(CGRect(x: x, y: size.height - height - 1, width: 1, height: height)),
                    with: .color(
                        tick.isMajor
                            ? Palette.dimmed.color()
                            : Palette.dimmed.color(opacity: 0.45)))

                if let label = tick.label, x + 44 < size.width {
                    context.draw(
                        Text(label)
                            .font(Typography.tick)
                            .foregroundStyle(Palette.dimmed.color()),
                        at: CGPoint(x: x + 4, y: 8),
                        anchor: .leading)
                }
            }

            drawSelectionMarkers(in: &context, size: size)
        }
        .frame(height: 24)
    }

    /// The selection edges repeat on the ruler so the in/out points stay findable
    /// when the lanes are busy.
    private func drawSelectionMarkers(in context: inout GraphicsContext, size: CGSize) {
        let range = model.selection.range
        guard !range.isEmpty else { return }
        for frame in [range.start, range.end] {
            let x = model.viewport.pixel(forFrame: frame)
            guard x >= 0, x <= size.width else { continue }
            context.fill(
                Path(CGRect(x: x - 1, y: size.height - 5, width: 2, height: 5)),
                with: .color(Palette.selection.color()))
        }
    }
}
