import ArtscribeKit
import AudioDecode
import CoreGraphics
import Foundation
import Observation
import Playback
import Waveform

/// Everything the viewer window shows, and every action it can perform.
///
/// The view layer reads this and calls its methods; it never mutates `Viewport`
/// or `Selection` directly, so there is exactly one place where a state change
/// can invalidate the cached waveform bitmap.
@MainActor
@Observable
public final class ViewerModel {

    // MARK: - Loaded track
    //
    // Written by `open(url:)` and its continuations, which live in
    // `ViewerModel+Loading` — hence `internal(set)` rather than `private(set)`:
    // Swift's `private` is file-scoped, and the loading pipeline is a file of
    // its own so this one stays inside the project's 400-line limit. Nothing
    // outside the module can write them either way.

    public internal(set) var fileName: String?
    /// Held for the lifetime of the loaded track: `DecodedAudio.channel(_:)`
    /// hands out raw pointers into this value's storage.
    public internal(set) var audio: DecodedAudio?
    public internal(set) var pyramid: PeakPyramid?

    public internal(set) var isLoading = false
    public internal(set) var progress: Double = 0
    /// Which real stage of `open(url:)` is currently running, shown beside the
    /// progress bar so a long wait says *why*, not merely that it is waiting.
    /// `nil` when nothing is loading. Each case corresponds to genuinely
    /// distinct work — there is no timer-driven guessing here.
    public internal(set) var loadPhase: LoadPhase?
    /// Set from `DecodeError.errorDescription`. Shown as an inline banner; the
    /// previously loaded track stays loaded (spec §8, never degrade silently).
    public internal(set) var errorMessage: String?
    /// Seconds from "file chosen" to "waveform rasterised", for the status bar.
    public internal(set) var lastLoadSeconds: Double?

    public enum LoadPhase: Sendable {
        /// Between `open(url:)` being called and the decoder's first progress
        /// callback — the file is being located and its header parsed.
        case opening
        /// The decoder is reporting chunk progress.
        case decoding
        /// Decode finished; `PeakPyramid.build` and the bitmap rasterisation
        /// are running.
        case buildingWaveform

        public var label: String {
            switch self {
            case .opening: return "Opening…"
            case .decoding: return "Decoding audio…"
            case .buildingWaveform: return "Building waveform…"
            }
        }
    }

    // MARK: - View state

    /// Mutated only through the methods in `ViewerModel+Interaction`, so the
    /// view layer cannot move the view without going past `refresh()`.
    public internal(set) var viewport = Viewport(totalFrames: 0, widthPixels: 1)
    public internal(set) var selection = Selection()
    /// The audible position. Written by `seek(to:)` for a user action and by the
    /// display-link poll of `PlaybackEngine.currentFrame` during playback — never
    /// pushed from the audio thread. Zoom anchors here, so the frame under the
    /// cursor stays put as you zoom.
    public internal(set) var playhead: FrameIndex = 0

    // MARK: - Playback state
    //
    // See `ViewerModel+Playback` for the actions that maintain these. The stored
    // properties live here because Swift has no stored properties in extensions.

    public internal(set) var speed = SpeedState()
    public internal(set) var loop = LoopRegion()
    /// How far `Z`/`X`, `⇧Z`/`⇧X` and `⌥Z`/`⌥X` move (spec §6.2).
    ///
    /// The applied value lives here, and `NudgeSettings` is only its backing
    /// tape: the menu titles and the nudge actions both read this, so there is
    /// one source of truth. Starts at the shipped defaults and is replaced once
    /// by `attach(nudge:)` at launch — a model built by a unit test therefore
    /// never touches the user's real preferences.
    public internal(set) var nudgeAmounts = NudgeAmounts.defaults
    /// How far `C`/`V` and `⌥C`/`⌥V` slide the whole selection (spec §6.2).
    /// Same arrangement as `nudgeAmounts`: the applied value lives here and
    /// `InteractionSettings` is only its backing tape.
    public internal(set) var selectionMoveAmounts = SelectionMoveAmounts.defaults
    /// Whether a vertical drag *up* zooms in. `false` — the shipped default —
    /// means down zooms in, which is the direction the user asked for after
    /// driving Task 16's. Governs both vertical drags and the wheel zoom, so
    /// one window never holds two zoom conventions at once.
    public internal(set) var invertZoomDrag = false
    /// Output level and mute. Half scale by default, and it survives a load: how
    /// loud you want it is a property of your headphones, not of the file.
    public internal(set) var volume = VolumeState()
    /// Spec §8 in the transport: an output that could not be opened, a route
    /// change, a stall, or a rejected command. Shown as an inline banner, never a
    /// modal, and never cleared by anything but the user.
    public internal(set) var playbackNotice: String?
    /// The render-thread counters, polled alongside the playhead.
    public internal(set) var degradation = DegradationCounts()

    /// What the *user* asked for, not `PlaybackEngine.isPlaying` — see
    /// `TransportLatch` for why reading the engine directly is a trap.
    public var isPlaying: Bool { transport.isPlaying }
    /// False when there is a track but no working audio graph, which is what the
    /// menu greys out on.
    public var canPlay: Bool { session != nil }
    /// True when the graph is resampling between the file and the device. Not a
    /// failure, but the user is entitled to know (spec §8).
    ///
    /// Stored rather than computed: answering it means asking `AVAudioEngine`
    /// for an `AVAudioFormat`, and the status bar reads it on every frame while
    /// the playhead moves. Refreshed whenever the graph could have changed.
    public internal(set) var isResampling = false

    var transport = TransportLatch()
    var session: PlaybackSession?
    /// Set when the engine stopped by itself at end of file. Distinguishes "the
    /// file ran out" from "the user pressed pause", which is what keeps the play
    /// button from flickering when play is pressed at the end.
    var reachedEnd = false
    /// When the output device's sample rate was last queried; see `tickPlayback`.
    @ObservationIgnored var lastRateCheck: Double = 0
    @ObservationIgnored var devices: OutputDeviceController?
    /// The Open Recent list, if the app shell attached one. Recorded here rather
    /// than at the three call sites that can open a file (menu, drop, the recent
    /// list itself), so a new way in cannot forget to.
    @ObservationIgnored var recents: RecentFiles?
    /// Where `nudgeAmounts` is persisted, if the app shell attached a store.
    /// Absent in unit tests, which is what keeps them off `UserDefaults`.
    @ObservationIgnored var nudgeStore: NudgeSettings?
    /// Where the zoom direction and the selection-move amounts are persisted,
    /// if the app shell attached a store. Absent in unit tests, which is what
    /// keeps them off `UserDefaults`.
    @ObservationIgnored var interactionStore: InteractionSettings?
    @ObservationIgnored let clock = PlayheadClock()

    /// Written only by `refresh()` in `ViewerModel+Rendering`, which is why the
    /// setter is module-internal rather than private.
    public internal(set) var waveformImage: CGImage?
    public internal(set) var overviewImage: CGImage?

    /// Which look the cached bitmaps were rasterised in.
    ///
    /// The model has to know the theme even though it draws nothing itself:
    /// `WaveformRenderer` writes colours straight into the bitmap, so a theme
    /// change has to invalidate the cache and re-render, and the cache key is
    /// here. The view layer pushes this in from the environment's colour scheme
    /// (`DocumentView`), which is also what makes `system` follow macOS.
    public private(set) var appearance: Appearance = .dark

    /// Switching theme touches nothing but the pixels: position, selection,
    /// loop, zoom and the audio graph are all untouched, so playback carries on
    /// across it.
    public func setAppearance(_ appearance: Appearance) {
        guard appearance != self.appearance else { return }
        self.appearance = appearance
        refresh()
    }

    public var sampleRate: Double { audio?.sampleRate ?? 0 }
    public var channels: Int { audio?.channels ?? 0 }
    public var totalFrames: FrameIndex { audio?.frameCount ?? 0 }
    public var hasTrack: Bool { audio != nil }

    /// Frames per point, i.e. how much timeline one point of screen covers.
    public var framesPerPixel: Double { viewport.framesPerPixel }

    /// Zoom relative to whole-file, so the readout reads `1.0x` when fitted.
    public var zoomFactor: Double {
        let fitted = viewport.maxFramesPerPixel
        guard fitted > 0, viewport.framesPerPixel > 0 else { return 1 }
        return fitted / viewport.framesPerPixel
    }

    // MARK: - Internal state
    //
    // Module-internal rather than private so `ViewerModel+Rendering` and
    // `ViewerModel+Interaction` can reach it; nothing outside the module can.

    /// Bumped on every successful load so cached bitmaps from the previous file
    /// can never be mistaken for valid.
    var generation = 0
    var laneSize = CGSize(width: 1, height: 1)
    var overviewSize = CGSize(width: 1, height: 1)
    /// Hit-test rectangles for pointer-anchored zoom; see `setLaneFrame`.
    /// Nothing draws from these, so they stay out of observation. Readable from
    /// outside so the acceptance harness can aim the pointer at a real lane
    /// instead of hard-coding a layout.
    @ObservationIgnored public internal(set) var laneFrame: CGRect = .zero
    @ObservationIgnored public internal(set) var overviewFrame: CGRect = .zero
    /// Where the time ruler landed, for the same reason as the two above: a
    /// real pointer has to be aimed at its 24 points to drive the zoom drag.
    @ObservationIgnored public internal(set) var rulerFrame: CGRect = .zero
    /// Where each transport button landed, in the same coordinates, for the same
    /// reason: the acceptance run clicks the real button rather than guessing at
    /// a layout. `@ObservationIgnored` like the others — nothing draws from it,
    /// and a dictionary rewritten on every layout pass would invalidate the
    /// window if it were observed.
    @ObservationIgnored public internal(set) var transportFrames: [TransportControl: CGRect] = [:]
    var scale: CGFloat = 2
    var renderedKey: WaveformRenderer.Key?
    var overviewKey: WaveformRenderer.Key?
    /// Module-internal, not private, so `ViewerModel+Loading` can reach it —
    /// Swift has no stored properties in extensions.
    var loadTask: Task<Void, Never>?
    /// Identifies the in-flight load. A load cancelled mid-flight can already be
    /// past its cancellation check and merely waiting for the main actor, so the
    /// token — not the `Task`— is what decides whose result is still wanted.
    var loadToken = 0
    var dragOrigin: Double?
    var lastClick: (pixel: Double, time: Double)?
    /// The vertical drag-to-zoom currently in flight — a bare drag on the time
    /// ruler, or an ⌥-drag in the lanes. `nil` between gestures.
    ///
    /// `@ObservationIgnored` like the hit-test frames: nothing in any `body`
    /// reads it, and it is rewritten on every pointer event, so observing it
    /// would invalidate the window sixty times a second for nothing. The redraw
    /// a drag really does need comes from the viewport it moves.
    @ObservationIgnored var zoomDrag: ZoomDrag?
    /// Where the left-drag in flight in the lanes began, which is what
    /// identifies one gesture across its events. `@ObservationIgnored` for the
    /// same reason as `zoomDrag`: nothing draws from it.
    @ObservationIgnored var laneDragStart: CGPoint?
    /// What that drag was decided to mean, latched at mouse-down. See
    /// `laneDragChanged` for why it cannot be re-read per event.
    ///
    /// Observed, unlike its companion above, because the pointer cursor follows
    /// it: an ⌥-drag that outlives the ⌥ that started it has to keep saying
    /// "zoom". Written exactly twice per gesture — mouse-down and mouse-up —
    /// not once per event, so it costs two body evaluations, not sixty a second.
    var laneDragMode: LaneDragMode?

    /// Each `E`/`R` press changes zoom by this factor. A half-octave keeps the
    /// key-repeat sweep readable instead of jumping past the detail you want.
    static let zoomStep = 1.4142135623730951
    /// A keyboard pan moves by this fraction of the visible width, so panning
    /// speed follows zoom instead of crawling when zoomed in. Left on the View
    /// menu's Scroll items and the trackpad; `Z`/`X` are the nudge keys (spec
    /// §6.2), and moving the playhead brings the view with it anyway.
    static let panFraction = 0.12
    static let doubleClickSeconds = 0.4
    static let clickSlopPoints = 3.0

    public init() {}

    // MARK: - Geometry

    /// Gives the model somewhere to record successfully opened files.
    public func attach(recents: RecentFiles) {
        self.recents = recents
    }

    public func setLaneSize(_ size: CGSize, scale: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        let changed = size != laneSize || scale != self.scale
        laneSize = size
        self.scale = Swift.max(1, scale)
        guard changed else { return }
        viewport.resize(widthPixels: lanePointWidth)
        refresh()
    }

    public func setOverviewSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != overviewSize else { return }
        overviewSize = size
        refresh()
    }

    /// Where the lanes sit in the window, in SwiftUI's global (content-view)
    /// coordinates. Only pointer-anchored zoom needs it: a scroll event arrives
    /// at the window, not at a view, so the hit test happens here.
    ///
    /// Deliberately not part of `setLaneSize`: a window *move* changes neither
    /// size nor scale and must not invalidate the bitmap, while a window
    /// *resize* changes both frames and only one of them matters to rendering.
    public func setLaneFrame(_ frame: CGRect) {
        laneFrame = frame
    }

    public func setOverviewFrame(_ frame: CGRect) {
        overviewFrame = frame
    }

    public func setRulerFrame(_ frame: CGRect) {
        rulerFrame = frame
    }

    public func setTransportFrame(_ frame: CGRect, for control: TransportControl) {
        transportFrames[control] = frame
    }

    var lanePointWidth: Int { Swift.max(1, Int(laneSize.width.rounded())) }

    // MARK: - Testing

    /// Adopts a track synchronously, bypassing the async decode pipeline.
    ///
    /// `audio`/`pyramid` have no public setter — `open(url:)` is the only
    /// production path — so unit tests over `ViewerModel+Interaction` (the drag
    /// and click state machine) need a same-module seam to reach a state where
    /// `hasTrack` is true. Internal, not public: invisible outside `ArtscribeUI`,
    /// so only `ArtscribeUITests` can reach it via `@testable import`.
    func loadForTesting(audio: DecodedAudio, pyramid: PeakPyramid, widthPixels: Int = 1000) {
        self.audio = audio
        self.pyramid = pyramid
        fileName = "test-track"
        generation += 1
        selection.clear()
        loop = LoopRegion()
        playhead = 0
        reachedEnd = false
        viewport = Viewport(totalFrames: audio.frameCount, widthPixels: widthPixels)
    }
}
