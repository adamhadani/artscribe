import ArtscribeKit
import SwiftUI

/// What a grabbable edge looks like under the pointer, and what it looks like
/// while it is being moved (Task 23).
///
/// A separate layer above the waveform `Canvas` rather than more drawing inside
/// it, for two reasons. The `Canvas` is the app's steady-state picture — lanes,
/// selection, loop, playhead — and this is transient chrome that appears and
/// goes; and a `Canvas` cannot cross-fade, whereas an opacity on a `Rectangle`
/// can, which is what lets the hover treatment arrive without jumping and lets
/// **Reduce Motion** switch that arrival off.
///
/// ## The treatment
///
/// The app's ink is already spoken for — violet is the loop, amber the
/// selection, teal the playhead — so nothing here introduces a colour. An edge
/// under the pointer is drawn in *its own region's ink*, which is what makes the
/// response unmistakable without being loud.
///
/// - **Hover.** The 2 pt edge goes to 3 pt and to full opacity, and an 18 pt
///   gradient wash falls away from it *into the region*. The wash is the one
///   piece of information a bare line cannot carry: which side of this line the
///   region lives on. It is what makes a swap legible the moment it happens.
/// - **Drag.** A full-height 2 pt guide at the frame the edge will land on, a
///   wider wash, and a small monospaced time flag under the loop bar — the
///   legend on a fader cap, set in the same face the status bar's POSITION uses.
/// - **The loop body.** Its two bars thicken by a point or two. Deliberately no
///   more than that: the bars *are* the handle, and turning the whole region
///   into a lit panel would drown the waveform underneath it.
struct TimelineEdgeOverlay: View {
    let model: ViewerModel
    /// The handle under a stationary pointer, resolved by the lanes.
    let hovering: TimelineHandle?

    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let hoverEdgeWidth: Double = 3
    private static let guideWidth: Double = 2
    private static let hoverWashWidth: Double = 18
    private static let dragWashWidth: Double = 26
    private static let washOpacity: Double = 0.18
    /// The time flag's centre, measured down from the top so it clears the
    /// loop's own bar and sits in the quiet band above the waveform's body.
    private static let flagCentreY: Double = Palette.loopBarHeight + 15
    /// Half of the widest flag this can hold — `h:mm:ss.SSS` at 11 pt
    /// monospaced, plus its padding. Used to keep the flag inside the lane
    /// rather than letting it hang off the edge of the window.
    private static let flagHalfWidth: Double = 62

    var body: some View {
        // Read at body level, never inside the `GeometryReader` closure:
        // SwiftUI's `@Observable` tracking is only guaranteed for reads that
        // happen while `body` itself is being evaluated, and that closure runs
        // during layout. The same trap `WaveformLanesView` records.
        let drag = model.edgeDrag
        let viewport = model.viewport
        let loopRange = model.loop.range
        let selectionRange = model.selection.range
        let sampleRate = model.sampleRate

        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                if let drag {
                    if drag.handle == .loopBody {
                        bars(loopRange, viewport: viewport, size: size, extra: 2)
                    } else {
                        draw(
                            Mark(
                                frame: drag.currentFrame, width: Self.guideWidth,
                                wash: Self.dragWashWidth, side: drag.side ?? .leading,
                                ink: ink(drag.handle)),
                            viewport: viewport, size: size)
                    }
                    flag(
                        TimeCode.precise(frames: drag.currentFrame, sampleRate: sampleRate),
                        atX: viewport.pixel(forFrame: drag.currentFrame),
                        ink: ink(drag.handle), size: size)
                } else if let hovering {
                    hover(
                        hovering, loopRange: loopRange, selectionRange: selectionRange,
                        viewport: viewport, size: size)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        // Reduce Motion turns the arrival off rather than making it slower: the
        // point of the setting is that nothing moves that did not have to. The
        // *drag* guide is never animated at either setting — it has to be
        // exactly where the pointer is, and 120 ms of easing on that would read
        // as lag.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }

    // MARK: - Pieces

    @ViewBuilder
    private func hover(
        _ handle: TimelineHandle,
        loopRange: FrameRange,
        selectionRange: FrameRange,
        viewport: Viewport,
        size: CGSize
    ) -> some View {
        if handle == .loopBody {
            bars(loopRange, viewport: viewport, size: size, extra: 1)
        } else if let mark = hoverMark(handle, loop: loopRange, selection: selectionRange) {
            draw(mark, viewport: viewport, size: size)
        }
    }

    private func hoverMark(
        _ handle: TimelineHandle, loop: FrameRange, selection: FrameRange
    ) -> Mark? {
        guard let side = handle.side,
            let frame = frame(of: handle, loop: loop, selection: selection)
        else { return nil }
        return Mark(
            frame: frame, width: Self.hoverEdgeWidth, wash: Self.hoverWashWidth, side: side,
            ink: ink(handle))
    }

    /// One drawn edge: where it is, how heavy it is, and which way its wash
    /// falls. A value rather than six arguments, because hover and drag differ
    /// only in the numbers.
    private struct Mark {
        let frame: FrameIndex
        let width: Double
        let wash: Double
        let side: TimelineEdgeSide
        let ink: RGB
    }

    /// A line, and the wash that says which side of it the region is on.
    private func draw(_ mark: Mark, viewport: Viewport, size: CGSize) -> some View {
        let x = viewport.pixel(forFrame: mark.frame)
        let intoTheRegion = mark.side == .leading
        return ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [mark.ink.color(opacity: Self.washOpacity), mark.ink.color(opacity: 0)],
                startPoint: intoTheRegion ? .leading : .trailing,
                endPoint: intoTheRegion ? .trailing : .leading
            )
            .frame(width: mark.wash, height: size.height)
            .offset(x: intoTheRegion ? x : x - mark.wash)
            Rectangle()
                .fill(mark.ink.color())
                .frame(width: mark.width, height: size.height)
                .offset(x: x - mark.width / 2)
        }
    }

    /// The loop's top and bottom bars, thickened. `extra` is how much taller
    /// than the drawn 4 pt they get: one point on hover, two while moving.
    private func bars(
        _ range: FrameRange, viewport: Viewport, size: CGSize, extra: Double
    ) -> some View {
        let left = Swift.max(0, viewport.pixel(forFrame: range.start))
        let right = Swift.min(size.width, viewport.pixel(forFrame: range.end))
        let height = Palette.loopBarHeight + extra
        return ZStack(alignment: .topLeading) {
            ForEach([0.0, size.height - height], id: \.self) { y in
                Rectangle()
                    .fill(palette.loop.color())
                    .frame(width: Swift.max(0, right - left), height: height)
                    .offset(x: left, y: y)
            }
        }
    }

    /// The live time readout, in the app's one monospaced readout face.
    ///
    /// Clamped inside the lane rather than allowed to hang off it: an edge
    /// dragged to the very start of the file would otherwise put half the
    /// number outside the window, which is where it is least readable and most
    /// needed.
    private func flag(_ text: String, atX x: Double, ink: RGB, size: CGSize) -> some View {
        let limit = Swift.max(Self.flagHalfWidth, size.width - Self.flagHalfWidth)
        return Text(text)
            .font(Typography.readout)
            .monospacedDigit()
            .foregroundStyle(palette.text.color())
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(palette.panel.color().opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(ink.color(opacity: 0.9), lineWidth: 1)
            )
            .fixedSize()
            .position(
                x: Swift.min(Swift.max(x, Self.flagHalfWidth), limit), y: Self.flagCentreY)
    }

    // MARK: - Which ink, which frame

    private func ink(_ handle: TimelineHandle) -> RGB {
        handle.isLoop ? palette.loop : palette.selection
    }

    private func frame(
        of handle: TimelineHandle, loop: FrameRange, selection: FrameRange
    ) -> FrameIndex? {
        switch handle {
        case .loopStart: return loop.start
        case .loopEnd: return loop.end
        case .selectionStart: return selection.start
        case .selectionEnd: return selection.end
        case .loopBody: return nil
        }
    }
}
