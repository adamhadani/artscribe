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

    public private(set) var fileName: String?
    /// Held for the lifetime of the loaded track: `DecodedAudio.channel(_:)`
    /// hands out raw pointers into this value's storage.
    public private(set) var audio: DecodedAudio?
    public private(set) var pyramid: PeakPyramid?

    public private(set) var isLoading = false
    public private(set) var progress: Double = 0
    /// Which real stage of `open(url:)` is currently running, shown beside the
    /// progress bar so a long wait says *why*, not merely that it is waiting.
    /// `nil` when nothing is loading. Each case corresponds to genuinely
    /// distinct work — there is no timer-driven guessing here.
    public private(set) var loadPhase: LoadPhase?
    /// Set from `DecodeError.errorDescription`. Shown as an inline banner; the
    /// previously loaded track stays loaded (spec §8, never degrade silently).
    public private(set) var errorMessage: String?
    /// Seconds from "file chosen" to "waveform rasterised", for the status bar.
    public private(set) var lastLoadSeconds: Double?

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
    @ObservationIgnored let clock = PlayheadClock()

    /// Written only by `refresh()` in `ViewerModel+Rendering`, which is why the
    /// setter is module-internal rather than private.
    public internal(set) var waveformImage: CGImage?
    public internal(set) var overviewImage: CGImage?

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
    var scale: CGFloat = 2
    var renderedKey: WaveformRenderer.Key?
    var overviewKey: WaveformRenderer.Key?
    private var loadTask: Task<Void, Never>?
    /// Identifies the in-flight load. A load cancelled mid-flight can already be
    /// past its cancellation check and merely waiting for the main actor, so the
    /// token — not the `Task`— is what decides whose result is still wanted.
    private var loadToken = 0
    var dragOrigin: Double?
    var lastClick: (pixel: Double, time: Double)?

    /// Each `E`/`R` press changes zoom by this factor. A half-octave keeps the
    /// key-repeat sweep readable instead of jumping past the detail you want.
    static let zoomStep = 1.4142135623730951
    /// `Z`/`X` move by a fraction of the visible width, so panning speed follows
    /// zoom instead of crawling when zoomed in.
    static let panFraction = 0.12
    static let doubleClickSeconds = 0.4
    static let clickSlopPoints = 3.0

    public init() {}

    // MARK: - Loading

    public func open(url: URL) {
        loadTask?.cancel()
        errorMessage = nil
        isLoading = true
        progress = 0
        loadPhase = .opening
        let started = Date()
        loadToken += 1
        let token = loadToken
        let reporter = ProgressReporter { [weak self] value in
            Task { @MainActor in self?.reportProgress(value, token: token) }
        }

        // Detached, not a plain `Task`: a detached task never inherits the main
        // actor, so the decode and the pyramid build are guaranteed to run off
        // it no matter how nonisolated-async inheritance is configured. The
        // decoder polls `Task.isCancelled`, so cancelling this stops it early.
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let loaded = try await TrackLoader.load(
                    url: url, reporter: reporter,
                    onPhaseChange: { phase in
                        Task { @MainActor in self?.setPhase(phase, token: token) }
                    })
                try Task.checkCancellation()
                await self?.adopt(loaded, url: url, startedAt: started, token: token)
            } catch is CancellationError {
                await self?.cancelLoading(token: token)
            } catch DecodeError.cancelled {
                await self?.cancelLoading(token: token)
            } catch {
                await self?.fail(with: TrackLoader.message(for: error), token: token)
            }
        }
    }

    public func dismissError() {
        errorMessage = nil
    }

    private func reportProgress(_ value: Double, token: Int) {
        guard token == loadToken else { return }
        progress = value
        // The decoder only calls back once it is actually reading chunks, so
        // this is the genuine boundary between "opening" and "decoding".
        loadPhase = .decoding
    }

    private func setPhase(_ phase: LoadPhase, token: Int) {
        guard token == loadToken else { return }
        loadPhase = phase
    }

    private func adopt(_ loaded: LoadedTrack, url: URL, startedAt: Date, token: Int) {
        guard token == loadToken else { return }
        teardownSession()
        audio = loaded.audio
        pyramid = loaded.pyramid
        fileName = url.lastPathComponent
        generation += 1
        selection.clear()
        // Speed and engine deliberately survive a load — they are a working
        // preference, not a property of the file — but the loop cannot: its
        // frames mean nothing in a different recording.
        loop = LoopRegion()
        playhead = 0
        reachedEnd = false
        isLoading = false
        progress = 1
        loadPhase = nil
        viewport = Viewport(totalFrames: loaded.audio.frameCount, widthPixels: lanePointWidth)
        refresh()
        openSession(for: loaded.audio)
        // Measured through to the rasterised bitmap, not just the decode, so the
        // readout answers "how long until I saw the waveform" (spec §1.2).
        lastLoadSeconds = Date().timeIntervalSince(startedAt)
    }

    private func cancelLoading(token: Int) {
        guard token == loadToken else { return }
        isLoading = false
        loadPhase = nil
    }

    /// The decode failed. The previously loaded track is deliberately left
    /// untouched — a failed open must not throw away what you were working on.
    private func fail(with message: String, token: Int) {
        guard token == loadToken else { return }
        isLoading = false
        loadPhase = nil
        errorMessage = message
    }

    // MARK: - Geometry

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
