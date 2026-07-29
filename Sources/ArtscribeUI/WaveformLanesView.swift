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
    @Environment(\.palette) private var palette
    @Environment(\.displayScale) private var displayScale
    /// Whether ⌥ is down *right now*, which is what makes the cursor change
    /// under a stationary pointer rather than only on entry.
    ///
    /// Fed by `onModifierKeysChanged`, which reports the combined state of
    /// every attached keyboard and fires on the change itself — not on hover,
    /// and not on a drag. It flips twice per press of ⌥, so the two body
    /// evaluations it costs are two per keystroke, not two per frame.
    @State private var optionHeld = false
    /// Whether ⇧ is down right now, for the same reason and by the same route.
    /// With ⇧ held a drag extends the selection *even on top of a loop edge*
    /// (`LaneDragMode`'s precedence), so the edge affordance has to stand down
    /// or it would be promising a resize that will not happen.
    @State private var shiftHeld = false
    /// The loop or selection handle under the pointer, or `nil` over open lane.
    ///
    /// The *resolved handle* is stored rather than the pointer position, and it
    /// is written only when it changes: a hover fires many events a second, and
    /// storing the point would invalidate this view on every one of them for a
    /// picture that is identical. This way a pointer crossing 200 points of open
    /// lane costs zero body evaluations.
    @State private var hovering: TimelineHandle?

    /// Everything the overlay draw needs, read once at body level and handed
    /// down to the `Canvas` closure as a single value — not read piecemeal
    /// from `model` inside the closure, and not passed as a long parameter
    /// list either.
    private struct OverlayState {
        let channels: Int
        let selectionRange: FrameRange
        let viewport: Viewport
        let hasTrack: Bool
        let playhead: FrameIndex
        let loop: LoopRegion
        let isPlaying: Bool
    }

    var body: some View {
        // Read every value the overlay depends on here, at body level, rather
        // than inside the `Canvas` closure below. SwiftUI's `@Observable`
        // tracking is only guaranteed for reads that happen while a view's
        // `body` is being evaluated; a `Canvas` renderer closure runs as part
        // of the display list, not necessarily under that same tracking scope.
        // A pure selection change touches none of `body`'s other dependencies
        // (the bitmap is selection-invariant), so without this the selection
        // band and channel rules could freeze until an unrelated redraw.
        let state = OverlayState(
            channels: model.channels,
            selectionRange: model.selection.range,
            viewport: model.viewport,
            hasTrack: model.hasTrack,
            playhead: model.playhead,
            loop: model.loop,
            isPlaying: model.isPlaying)

        ZStack(alignment: .topLeading) {
            palette.panel.color()

            if let image = model.cache.waveformImage {
                // The bitmap is produced at `displayScale`, so this maps one
                // image pixel to one screen pixel and needs no smoothing.
                // `.resizable()` only matters for the frame between a live
                // resize and the redraw that follows it.
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .interpolation(.none)
            }

            Canvas(rendersAsynchronously: false) { context, size in
                draw(in: &context, size: size, state: state)
            }
            .allowsHitTesting(false)

            // Above the `Canvas`, because it is transient chrome over a
            // steady-state picture and because it has to be able to cross-fade.
            // See `TimelineEdgeOverlay`.
            TimelineEdgeOverlay(model: model, hovering: hovering)
        }
        .contentShape(.rect)
        // The lanes carry four drag behaviours and, until Task 17, advertised
        // none of them. The crosshair says a passage can be dragged out; ⌥
        // turns it into a magnifier, and back, with the pointer standing still;
        // and over a loop or selection edge it becomes the frame-resize arrow.
        // The scheme and its reasons are in `PointerAffordance`.
        .pointerStyle(
            PointerAffordance.over(
                .waveformLanes, optionHeld: optionHeld, shiftHeld: shiftHeld,
                laneDrag: model.laneDragMode, hovering: hovering
            ).pointerStyle
        )
        // Not `NSEvent.modifierFlags` polled from the gesture: that is only
        // read when an event arrives, and the whole point here is the frame in
        // which nothing is happening except a thumb on ⌥.
        .onModifierKeysChanged(mask: [.option, .shift]) { _, now in
            if now.contains(.option) != optionHeld { optionHeld = now.contains(.option) }
            if now.contains(.shift) != shiftHeld { shiftHeld = now.contains(.shift) }
        }
        // The hover half of Task 23. The cursor and the highlight both come
        // from this, so an edge announces itself before the mouse goes down —
        // which is the whole difference between a discoverable handle and a
        // hidden one.
        .onContinuousHover(coordinateSpace: .local) { phase in
            let found: TimelineHandle? =
                switch phase {
                case .active(let point): model.timelineHandle(at: point)
                case .ended: nil
                }
            if found != hovering { hovering = found }
        }
        .gesture(dragGesture)
        // The frame, not just the size: a scroll event arrives at the window, so
        // pointer-anchored zoom needs to know where this lane sits in it.
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: { frame in
            model.setLaneFrame(frame)
            model.setLaneSize(frame.size, scale: displayScale)
        }
    }

    /// Selection, ⇧-extend, or an ⌥-modified zoom. Which of the three it is gets
    /// decided by the model when the mouse goes down and held for the gesture's
    /// life — the flags are read live here, so the latch has to be there rather
    /// than here. See `ViewerModel.laneDragChanged`.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let modifiers = NSEvent.modifierFlags
                model.laneDragChanged(
                    start: value.startLocation,
                    current: value.location,
                    option: modifiers.contains(.option),
                    shift: modifiers.contains(.shift))
            }
            .onEnded { value in
                model.laneDragEnded(
                    start: value.startLocation,
                    end: value.location,
                    now: ProcessInfo.processInfo.systemUptime)
            }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, state: OverlayState) {
        drawChannelRules(in: &context, size: size, channels: state.channels)
        drawSelection(
            in: &context, size: size, range: state.selectionRange, viewport: state.viewport)
        drawLoop(in: &context, size: size, state: state)
        drawPlayhead(in: &context, size: size, state: state)
        drawChannelLabels(in: &context, size: size, channels: state.channels)
    }

    private func drawChannelRules(in context: inout GraphicsContext, size: CGSize, channels: Int) {
        guard channels > 1 else { return }
        let laneHeight = size.height / Double(channels)
        for lane in 1..<channels {
            let y = laneHeight * Double(lane)
            context.fill(
                Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                with: .color(palette.laneRule.color(opacity: 0.8)))
        }
    }

    private func drawSelection(
        in context: inout GraphicsContext, size: CGSize, range: FrameRange, viewport: Viewport
    ) {
        guard !range.isEmpty else { return }
        let startX = viewport.pixel(forFrame: range.start)
        let endX = viewport.pixel(forFrame: range.end)
        guard endX > 0, startX < size.width else { return }

        let left = max(0, startX)
        let right = min(size.width, endX)
        context.fill(
            Path(CGRect(x: left, y: 0, width: max(0, right - left), height: size.height)),
            with: .color(palette.selection.color(opacity: palette.selectionFillOpacity)))

        let edge = Palette.selectionEdgeWidth
        for x in [startX, endX] where x >= -edge && x <= size.width + edge {
            context.fill(
                Path(CGRect(x: x - edge / 2, y: 0, width: edge, height: size.height)),
                with: .color(palette.selection.color()))
        }
    }

    /// The loop region: bars along the top and bottom edges plus solid in/out
    /// posts. Deliberately a different *shape* as well as a different colour from
    /// the selection's full-height wash, because the two are shown together and
    /// mean different things. A region that exists but is switched off is drawn
    /// faintly rather than hidden — having set it is worth remembering.
    private func drawLoop(
        in context: inout GraphicsContext, size: CGSize, state: OverlayState
    ) {
        let range = state.loop.range
        guard state.hasTrack, !range.isEmpty else { return }
        let startX = state.viewport.pixel(forFrame: range.start)
        let endX = state.viewport.pixel(forFrame: range.end)
        guard endX > 0, startX < size.width else { return }

        let opacity = state.loop.isEnabled ? 1.0 : Palette.loopDisabledOpacity
        let colour = palette.loop.color(opacity: opacity)
        let bar = Palette.loopBarHeight
        let left = max(0, startX)
        let width = max(0, min(size.width, endX) - left)
        for y in [0.0, size.height - bar] {
            context.fill(
                Path(CGRect(x: left, y: y, width: width, height: bar)), with: .color(colour))
        }
        if state.loop.isEnabled {
            context.fill(
                Path(CGRect(x: left, y: 0, width: width, height: size.height)),
                with: .color(palette.loop.color(opacity: 0.07)))
        }
        for x in [startX, endX] where x >= -2 && x <= size.width + 2 {
            context.fill(
                Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(colour))
        }
    }

    /// The playhead, and the zoom anchor. Always drawn once a track is loaded —
    /// before playback existed it was hidden behind a selection, which is exactly
    /// backwards now that it is the thing you are listening to.
    private func drawPlayhead(
        in context: inout GraphicsContext, size: CGSize, state: OverlayState
    ) {
        guard state.hasTrack else { return }
        let x = state.viewport.pixel(forFrame: state.playhead)
        guard x >= -1, x <= size.width + 1 else { return }
        let width = state.isPlaying ? 2.0 : 1.0
        context.fill(
            Path(CGRect(x: x - width / 2, y: 0, width: width, height: size.height)),
            with: .color(palette.accent.color(opacity: state.isPlaying ? 1.0 : 0.85)))
    }

    private func drawChannelLabels(
        in context: inout GraphicsContext, size: CGSize, channels: Int
    ) {
        guard channels > 0 else { return }
        let laneHeight = size.height / Double(channels)
        for lane in 0..<channels {
            let text = Text(Self.channelLabel(lane, of: channels))
                .font(Typography.laneLabel)
                .foregroundStyle(palette.dimmed.color())
            context.draw(
                text, at: CGPoint(x: 8, y: laneHeight * Double(lane) + 10), anchor: .leading)
        }
    }

    static func channelLabel(_ index: Int, of total: Int) -> String {
        guard total == 2 else { return "CH\(index + 1)" }
        return index == 0 ? "L" : "R"
    }
}
