import ArtscribeKit

/// Everything the transport bar draws from, as a value.
///
/// A plain struct rather than the model itself so the bar's presentation rules —
/// which button is live, which reads as *on*, how the speed is written — are
/// testable without building an audio graph. `ViewerModel.transportState`
/// produces it; nothing else should.
public struct TransportState: Equatable, Sendable {
    public var hasTrack = false
    public var isPlaying = false
    /// The loop region has no frames in it. Kept apart from `loopIsEnabled`
    /// because a loop switched on with no region is a state you must be able to
    /// leave — see `TransportControl.loop`'s enablement.
    public var loopIsEmpty = true
    public var loopIsEnabled = false
    public var selectionIsEmpty = true
    public var speedRatio = 1.0

    public init() {}

    /// The same string the status bar shows, from the same formatter.
    public var speedLabel: String { SpeedStepping.percentLabel(speedRatio) }

    /// The status bar's rule, not a second one: a speed that is not 100% is the
    /// piece of state you can forget you left on, so it shouts in both places or
    /// the two readouts disagree about what "changed" looks like.
    public var speedIsEmphasised: Bool { SpeedStepping.isAltered(speedRatio) }
}

/// One button on the transport bar.
///
/// Deliberately an enum and not a pile of closures in the view: it is the list of
/// what the bar offers, it is what `ViewerModel.perform(_:)` switches over, and it
/// is the only place a button's symbol, title, shortcut and enablement are
/// written down. A button that needed logic of its own would have to add a case
/// here and a line to `perform`, which puts the logic on the model where it can
/// be tested — the whole point of the arrangement.
public enum TransportControl: String, CaseIterable, Sendable, Hashable {
    /// The coarse tier backwards — the Playback menu already calls it "Rewind".
    case rewind
    case nudgeBackward
    case playPause
    case nudgeForward
    /// The coarse tier forwards — "Skip" in the Playback menu.
    case skip
    case playFromStart
    case loop
    case slower
    case faster
    case zoomOut
    case zoomIn

    /// The bar's layout, in order, separated by rules. Flattening this must give
    /// `allCases` back, which is asserted rather than assumed.
    public static let groups: [[TransportControl]] = [
        [.rewind, .nudgeBackward, .playPause, .nudgeForward, .skip],
        [.playFromStart],
        [.loop],
        [.slower, .faster],
        [.zoomOut, .zoomIn]
    ]

    /// What one button says and draws in its resting state.
    ///
    /// A table rather than three parallel switches: the three facts about a
    /// button belong together, and a case added without them is then a missing
    /// row rather than three separate omissions. `TransportControlTests` walks
    /// `allCases` and asserts every one has a shortcut and a resolvable SF
    /// Symbol, so the fallback below is unreachable and provably so.
    struct Face: Sendable {
        let shortcut: String
        let title: String
        let symbol: String
    }

    private static let faces: [TransportControl: Face] = [
        .rewind: Face(shortcut: "⌥Z", title: "Rewind", symbol: "backward.fill"),
        .nudgeBackward: Face(shortcut: "Z", title: "Nudge Back", symbol: "backward.frame.fill"),
        .playPause: Face(shortcut: "Space", title: "Play", symbol: "play.fill"),
        .nudgeForward: Face(shortcut: "X", title: "Nudge Forward", symbol: "forward.frame.fill"),
        .skip: Face(shortcut: "⌥X", title: "Skip", symbol: "forward.fill"),
        .playFromStart: Face(
            shortcut: "Return", title: "Play from Selection Start", symbol: "backward.end.fill"),
        .loop: Face(shortcut: "D", title: "Loop", symbol: "repeat"),
        .slower: Face(shortcut: "Q", title: "Slower", symbol: "minus"),
        .faster: Face(shortcut: "W", title: "Faster", symbol: "plus"),
        .zoomOut: Face(shortcut: "E", title: "Zoom Out", symbol: "minus.magnifyingglass"),
        .zoomIn: Face(shortcut: "R", title: "Zoom In", symbol: "plus.magnifyingglass")
    ]

    private var face: Face {
        Self.faces[self] ?? Face(shortcut: "", title: rawValue, symbol: "questionmark")
    }

    /// The key that already does this, written as it appears in a menu. The bar
    /// exists to teach the keyboard, not to replace it, so every control has one.
    public var shortcut: String { face.shortcut }

    /// Follows the transport for play/pause, because a button that says "Play"
    /// while playing is lying about what pressing it will do — the same rule the
    /// Playback menu's first item follows.
    public func title(in state: TransportState) -> String {
        switch self {
        case .playPause: return state.isPlaying ? "Pause" : "Play"
        case .loop: return state.loopIsEnabled ? "Looping — Turn Off" : "Loop"
        default: return face.title
        }
    }

    /// The loop button keeps one glyph in both states and carries its state in
    /// the tint and the fill instead. A glyph that changed shape as well would
    /// move the row's geometry every time the loop is toggled, and the state is
    /// already unmistakable without it.
    public func symbol(in state: TransportState) -> String {
        self == .playPause && state.isPlaying ? "pause.fill" : face.symbol
    }

    public func tooltip(in state: TransportState) -> String {
        "\(title(in: state))  (\(shortcut))"
    }

    /// Nothing is live without a track, matching every action on the model, all
    /// of which are guarded no-ops in that state.
    ///
    /// The loop button adds the Loop menu item's exact rule: with no region and
    /// looping off there is nothing to toggle, but looping *on* with no region
    /// has to remain switchable-off.
    public func isEnabled(in state: TransportState) -> Bool {
        guard state.hasTrack else { return false }
        switch self {
        case .loop: return !(state.loopIsEmpty && !state.loopIsEnabled)
        default: return true
        }
    }

    /// Whether the button should draw as engaged. Only the loop has one: play and
    /// pause are one button whose glyph already says which it is, and the rest are
    /// momentary.
    public func isOn(in state: TransportState) -> Bool {
        self == .loop && state.loopIsEnabled
    }
}

extension ViewerModel {

    /// What the transport bar draws from.
    public var transportState: TransportState {
        var state = TransportState()
        state.hasTrack = hasTrack
        state.isPlaying = isPlaying
        state.loopIsEmpty = loop.range.isEmpty
        state.loopIsEnabled = loop.isEnabled
        state.selectionIsEmpty = selection.isEmpty
        state.speedRatio = speed.ratio
        return state
    }

    /// The transport bar's single entry point.
    ///
    /// Every case is one call to a method the keyboard and the menu already
    /// invoke — that is the property this method exists to make checkable, and
    /// `TransportControlTests` checks it by driving the same models down both
    /// paths and comparing. Nothing is guarded here: each of these already guards
    /// itself on `hasTrack`, and duplicating that would mean two rules to keep in
    /// step.
    public func perform(_ control: TransportControl) {
        switch control {
        case .rewind: nudge(.coarse, direction: .backward)
        case .nudgeBackward: nudge(.normal, direction: .backward)
        case .playPause: togglePlayPause()
        case .nudgeForward: nudge(.normal, direction: .forward)
        case .skip: nudge(.coarse, direction: .forward)
        case .playFromStart: playFromStart()
        default: performSpeedOrView(control)
        }
    }

    /// The other half of `perform`, split only to keep each switch inside the
    /// project's complexity limit. The dispatch is still one case per control.
    private func performSpeedOrView(_ control: TransportControl) {
        switch control {
        case .loop: toggleLoop()
        case .slower: slower(fine: false)
        case .faster: faster(fine: false)
        case .zoomOut: zoomOut()
        case .zoomIn: zoomIn()
        default: break
        }
    }
}
