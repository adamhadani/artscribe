import ArtscribeKit
import CoreGraphics
import Foundation

/// A vertical drag that zooms, in flight.
///
/// The gesture comes from the tools this one sits beside: Ableton Live
/// documents "click and drag vertically in the beat-time ruler to smoothly
/// change the zoom level", and Melodyne does the same.
///
/// **Drag down to zoom in.** Neither of those manuals states which way theirs
/// runs, so Task 16 picked up-to-zoom-in on internal consistency with the
/// wheel. The user has since driven it and prefers down; a hand on the trackpad
/// beats an argument from another app's undocumented behaviour, so down is the
/// shipped direction and `inverted` — Settings ▸ Playback ▸ *Invert zoom
/// direction* — puts the old one back without a rebuild.
///
/// Two properties are what make it worth having over the stepped controls that
/// already exist:
///
/// **Smooth.** The factor is `pow(2, travel / pointsPerDoubling)` — continuous
/// in the pointer position, with no notch, no rounding and no dead zone. Every
/// point of travel moves the zoom.
///
/// **Absolute.** `factor(atY:currentFramesPerPixel:)` answers "what does the
/// viewport have to be multiplied by to reach the zoom this pointer position
/// means", not "how much further since the last event". A gesture that
/// integrated per-event increments would drift with the event rate, and would
/// stay pinned at the viewport's zoom limit for the whole return journey once
/// it had pushed past it. This one comes straight back.
///
/// The natural-scrolling preference is deliberately not consulted. It applies
/// to scroll events, not to pointer motion: a drag is direct manipulation, and
/// the pointer follows the hand under either setting. Inverting here would
/// break the gesture for exactly the users who flipped it — the same trap
/// `TrackpadAction` documents for `isDirectionInvertedFromDevice`.
struct ZoomDrag: Equatable, Sendable {
    /// Where the drag began, local to the view that owns it. Only `x` (the
    /// anchor) and `y` (the travel) are used; the point is kept whole because
    /// it is also what identifies the gesture across events.
    let start: CGPoint
    /// The frame under `start.x` when the drag began. Fixed for the gesture's
    /// life, so the thing you pointed at stays under the pointer throughout —
    /// re-deriving it each event would let rounding walk it sideways.
    let anchorFrame: FrameIndex
    let startFramesPerPixel: Double
    /// What the viewport actually read after this gesture's last event, which
    /// is not always what was asked for — `Viewport.zoom` clamps. Compared
    /// against the live viewport to notice that something *else* moved it (a
    /// window resize re-clamps `framesPerPixel`, and the keyboard zoom is still
    /// live during a drag); the gesture then restarts from where the viewport
    /// really is rather than yanking it back to where the drag began.
    var appliedFramesPerPixel: Double
    /// The user's direction preference, **latched when the gesture began**.
    /// Read once rather than per event for the same reason `LaneDragMode` is:
    /// what a gesture means is decided when the mouse goes down, and a value
    /// that changed underneath it would invert the zoom under the hand.
    let inverted: Bool

    init(
        start: CGPoint, anchorFrame: FrameIndex, startFramesPerPixel: Double,
        inverted: Bool = false
    ) {
        self.start = start
        self.anchorFrame = anchorFrame
        self.startFramesPerPixel = startFramesPerPixel
        self.appliedFramesPerPixel = startFramesPerPixel
        self.inverted = inverted
    }

    /// Points of vertical travel per doubling of zoom. A quarter of a tall
    /// window's height is worth about four times the zoom, which lands between
    /// "nothing happens" and "one twitch and you are lost".
    static let pointsPerDoubling = 120.0

    /// Ceiling on one gesture's travel, in points. Ten doublings each way is
    /// far past what the viewport itself allows on any real file; the clamp is
    /// there so a synthesised or absurd pointer position cannot hand `pow` an
    /// exponent that overflows to infinity.
    static let maxTravelPoints = 10 * pointsPerDoubling

    /// Zoom relative to where the gesture began. Greater than 1 means zoomed
    /// in. `nil` for a position that is not a number.
    ///
    /// - Parameter inverted: the user's preference. `false` — the default —
    ///   means a downward drag zooms in.
    static func cumulativeFactor(
        fromY startY: Double, toY y: Double, inverted: Bool = false
    ) -> Double? {
        guard startY.isFinite, y.isFinite else { return nil }
        // Top-left origin: dragging down makes `y` larger, so down is positive.
        // Inverting negates the travel, which makes the two directions exact
        // reciprocals of each other rather than merely opposite in sign.
        let signed = inverted ? startY - y : y - startY
        let travel = Swift.max(-maxTravelPoints, Swift.min(maxTravelPoints, signed))
        let factor = pow(2, travel / pointsPerDoubling)
        guard factor > 0, factor.isFinite else { return nil }
        return factor
    }

    /// The factor to hand `Viewport.zoom(by:anchorFrame:)` so the viewport
    /// lands on the zoom this pointer position means.
    ///
    /// - Parameter currentFramesPerPixel: the viewport's zoom right now, which
    ///   is what makes the result absolute rather than incremental.
    func factor(atY y: Double, currentFramesPerPixel: Double) -> Double? {
        guard let cumulative = Self.cumulativeFactor(fromY: start.y, toY: y, inverted: inverted)
        else { return nil }
        guard currentFramesPerPixel > 0, currentFramesPerPixel.isFinite else { return nil }
        let target = startFramesPerPixel / cumulative
        guard target > 0, target.isFinite else { return nil }
        let factor = currentFramesPerPixel / target
        guard factor > 0, factor.isFinite else { return nil }
        return factor
    }
}

/// What a left-drag in the waveform lanes means.
///
/// Decided once, when the mouse goes down, and held for the gesture's life. A
/// modifier pressed or released halfway through must not silently turn a
/// selection into a zoom or the other way about — you would be mid-gesture,
/// watching the wrong thing happen, with no way to undo it.
enum LaneDragMode: Equatable, Sendable {
    /// The core gesture, and not negotiable: a plain left-drag selects a
    /// passage. `extending` is ⇧-drag, which keeps the anchor and moves only
    /// the head.
    case select(extending: Bool)
    /// ⌥-drag. ⌥ because it collides with neither ⇧-drag (extend) nor ⌘-drag,
    /// and because Melodyne sets the precedent for a modifier-drag zoom inside
    /// the editing pane.
    case zoom
    /// A loop or selection handle taken hold of at mouse-down (Task 23). The
    /// handle is latched with the mode, so an edge dragged past its opposite
    /// number keeps being *this* drag rather than becoming a different one.
    case edge(TimelineHandle)

    /// The lanes' precedence rule, in one place. See `TimelineHandles` for the
    /// whole of it and for why it is ordered this way:
    ///
    /// 1. ⌥ → zoom. It beats everything, including a handle under the pointer.
    /// 2. ⇧ → extend the selection. Also beats a handle, which is what keeps a
    ///    selection edge reachable when a loop edge is sitting on top of it.
    /// 3. A handle under the pointer → drag it.
    /// 4. Otherwise → a new selection, exactly as before.
    ///
    /// ⌥ beating ⇧ when both are held is unchanged: holding both is a typo
    /// rather than a third gesture, and the same precedence already governs the
    /// nudge tiers.
    init(option: Bool, shift: Bool, handle: TimelineHandle? = nil) {
        if option {
            self = .zoom
        } else if shift {
            self = .select(extending: true)
        } else if let handle {
            self = .edge(handle)
        } else {
            self = .select(extending: false)
        }
    }
}
