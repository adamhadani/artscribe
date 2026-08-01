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
    public var prerollIsEnabled = true
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
    /// **The button a touch-only device cannot do without.**
    ///
    /// Dragging out a selection is the first thing anyone does to a waveform,
    /// and until this existed it dead-ended: the region was drawn, it was not a
    /// loop, and `.loop` only *toggles* one — it is disabled outright while the
    /// loop is empty and looping is off. The keyboard had `L`; a phone has no
    /// keyboard and iPadOS's menu bar needs one.
    case loopFromSelection
    case loop
    case preroll
    case slower
    case faster
    case zoomOut
    case zoomIn

    /// The bar's layout, in order, separated by rules. Flattening this must give
    /// `allCases` back, which is asserted rather than assumed.
    public static let groups: [[TransportControl]] = [
        [.rewind, .nudgeBackward, .playPause, .nudgeForward, .skip],
        [.playFromStart],
        [.loopFromSelection, .loop, .preroll],
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
            // Not "from Selection Start": since Task 22 it also aims at an
            // active loop's in point when there is no selection.
            shortcut: "⇧Space", title: "Play from Start",
            symbol: "backward.end.fill"),
        .loopFromSelection: Face(
            // `selection.pin.in.out` rather than a second `repeat` glyph: this
            // acts on the *selection*, and two repeat symbols side by side would
            // read as two ways of doing the same thing.
            //
            // `repeat.badge.plus` was the first choice and does not exist —
            // caught by `every control names a real SF Symbol`, which is exactly
            // why that test walks `allCases`.
            shortcut: "G", title: "Selection → Loop", symbol: "selection.pin.in.out"),
        .loop: Face(shortcut: "D", title: "Loop", symbol: "repeat"),
        // `arrow.uturn.backward` reads as "start a little earlier" rather than
        // as a rewind, which `backward.fill` next to it already owns.
        .preroll: Face(shortcut: "H", title: "Preroll", symbol: "arrow.uturn.backward"),
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

    /// What the button is called with no track loaded and nothing toggled.
    ///
    /// `title(in:)` is the one to use in the bar, because a button that says
    /// "Play" while playing is lying. Somewhere that is *describing* the control
    /// rather than offering it — the welcome tour — wants the plain noun, and
    /// `title(in: TransportState())` would give it "Preroll On — Turn Off".
    public var name: String { face.title }

    /// The resting glyph, independent of any state. Same reasoning as `name`.
    public var glyph: String { face.symbol }

    /// Follows the transport for play/pause, because a button that says "Play"
    /// while playing is lying about what pressing it will do — the same rule the
    /// Playback menu's first item follows.
    public func title(in state: TransportState) -> String {
        switch self {
        case .playPause: return state.isPlaying ? "Pause" : "Play"
        case .loop: return state.loopIsEnabled ? "Looping — Turn Off" : "Loop"
        case .preroll:
            return state.prerollIsEnabled ? "Preroll On — Turn Off" : "Preroll Off — Turn On"
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
        // Nothing to make a loop out of. Disabled rather than hidden: a control
        // that appears when you happen to have a selection is one you never
        // learn is there.
        case .loopFromSelection: return !state.selectionIsEmpty
        default: return true
        }
    }

    /// Whether the button should draw as engaged. Only the loop has one: play and
    /// pause are one button whose glyph already says which it is, and the rest are
    /// momentary.
    public func isOn(in state: TransportState) -> Bool {
        switch self {
        case .loop: return state.loopIsEnabled
        case .preroll: return state.prerollIsEnabled
        default: return false
        }
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
        state.prerollIsEnabled = prefs.prerollEnabled
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
    /// **Exhaustive on purpose — do not add a `default`.** This switch used to
    /// end in `default: break`, and a `.preroll` case added to the enum then
    /// compiled cleanly while its button did nothing: the key and the menu item
    /// worked, the button was inert, and no test failed because the both-paths
    /// test below enumerates controls by hand rather than walking `allCases`.
    /// Listing the cases `perform` already handled costs six words and turns the
    /// next omission into a build error instead of a silent dead button.
    private func performSpeedOrView(_ control: TransportControl) {
        switch control {
        case .loopFromSelection: loopFromSelection()
        case .loop: toggleLoop()
        case .preroll: togglePreroll()
        case .slower: slower(fine: false)
        case .faster: faster(fine: false)
        case .zoomOut: zoomOut()
        case .zoomIn: zoomIn()
        case .rewind, .nudgeBackward, .playPause, .nudgeForward, .skip, .playFromStart:
            preconditionFailure("\(control) is handled by perform(_:) and cannot reach here")
        }
    }
}
