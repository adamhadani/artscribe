/// What one track's practice session is (spec §7): speed, loop region, loop
/// enabled, viewport, playhead, and active engine.
///
/// Two types, deliberately:
///
/// - `SessionState` is what the app runs on. Every value in it is already
///   inside its own invariants, because it was either built by the app or put
///   through `restoring(_:frameCount:sampleRate:)`.
/// - `SessionFile` is what the JSON holds. Every field is optional, because the
///   sidecar is a **visible, user-editable file** and a half-written or
///   hand-edited one is a state this app must survive rather than a state it
///   may assume away.
///
/// The conversion between them is a pure function that says what it had to
/// change, so the app can surface a damaged sidecar instead of quietly
/// pretending it read one (spec §8).
public struct SessionState: Equatable, Sendable {
    public var speed: SpeedState
    /// Transposition. Durable like the speed, and for the same reason: it is a
    /// decision about the material, not a transient view state.
    public var pitch: PitchState
    public var loop: LoopRegion
    public var viewport: ViewportState
    public var playhead: FrameIndex
    /// Which recording these frame numbers were measured against. Frames mean
    /// nothing without it: the same sidecar beside a different master, a
    /// different edit, or a re-rip at another sample rate describes a passage
    /// that is no longer there.
    public var track: TrackIdentity
    /// Whether the cue-sheet track-marker lane is shown.
    ///
    /// Defaults to **true**, so a file that has a cue sheet shows its markers
    /// the first time it is opened — the discoverable behaviour. Only a user
    /// who deliberately put the lane away has anything to persist, and a
    /// sidecar written before this field existed reads as absent and gets the
    /// default rather than a hidden lane.
    public var showTrackMarks: Bool

    public init(
        speed: SpeedState = SpeedState(),
        pitch: PitchState = PitchState(),
        loop: LoopRegion = LoopRegion(),
        viewport: ViewportState = .fitted,
        playhead: FrameIndex = 0,
        track: TrackIdentity = TrackIdentity(),
        showTrackMarks: Bool = true
    ) {
        self.speed = speed
        self.pitch = pitch
        self.loop = loop
        self.viewport = viewport
        self.playhead = playhead
        self.track = track
        self.showTrackMarks = showTrackMarks
    }

    /// The on-disk form. Everything is present, because the app only ever
    /// writes complete files; the optionality on `SessionFile` is about what it
    /// may have to *read*.
    public var fileRepresentation: SessionFile {
        SessionFile(
            schemaVersion: SessionFile.currentSchemaVersion,
            track: track,
            speed: speed,
            pitch: pitch,
            loop: loop,
            viewport: viewport,
            playhead: playhead,
            showTrackMarks: showTrackMarks)
    }

    /// The fields that cannot be damaged, and so cannot be repaired.
    ///
    /// A `Bool` has no invalid value, and `PitchState`'s own decoder clamps
    /// before this is ever reached — so neither can contribute a
    /// `SessionRepair`, and neither belongs in the body of `restoring`, which
    /// is about values that *can* be wrong. Absent means "take the default" in
    /// both cases, which is what a sidecar written before these fields existed
    /// says.
    mutating func adoptUnrepairableFields(from file: SessionFile) {
        if let pitch = file.pitch { self.pitch = pitch }
        if let showTrackMarks = file.showTrackMarks { self.showTrackMarks = showTrackMarks }
    }

    /// Turns an untrusted payload into a state the app can run on, and reports
    /// everything it had to change on the way.
    ///
    /// The rule throughout is **clamp, do not discard**. A loop that runs off
    /// the end of the file is far more likely to be a track that was re-encoded
    /// a few frames shorter than a deliberate lie, and a user who spent ten
    /// minutes setting loop points would rather have them moved by 200 samples
    /// than deleted. The one thing that is never allowed is a value that
    /// contradicts an invariant something downstream relies on — a zero speed
    /// ratio (an infinite time ratio inside Rubber Band), a negative loop
    /// length, a NaN zoom.
    ///
    /// - Parameters:
    ///   - frameCount: the length of the recording actually loaded, which is
    ///     what every frame value is clamped against. Values below zero are
    ///     treated as an empty recording.
    ///   - sampleRate: the rate actually loaded, compared with the one recorded
    ///     in the file only to *report* a mismatch. Frames are not rescaled: a
    ///     sample rate that changed means a different file, and guessing at a
    ///     conversion would invent loop points nobody chose.
    public static func restoring(
        _ file: SessionFile, frameCount: FrameIndex, sampleRate: Double
    ) -> SessionRestoration {
        let total = Swift.max(0, frameCount)
        var repairs: [SessionRepair] = []
        var state = SessionState(
            track: TrackIdentity(sampleRate: sampleRate, frameCount: total))

        if file.schemaVersion != SessionFile.currentSchemaVersion {
            repairs.append(.schemaVersion)
        }

        // A `Bool` has no invalid value to clamp and nothing to repair — either
        // the key is there and is honoured, or it is absent and the default
        // stands. Absent is the normal case for every sidecar written before
        // this field existed, which is why it is not reported as damage.
        state.adoptUnrepairableFields(from: file)

        if let speed = file.speed {
            // No clamping needed here and none wanted: `SpeedState`'s own
            // decoder already refuses to construct an out-of-range ratio, which
            // is the precedent this whole file follows.
            state.speed = speed
        } else {
            repairs.append(.speed)
        }

        if let loop = file.loop {
            let clamped = LoopRegion(
                range: loop.range.clamped(to: total), isEnabled: loop.isEnabled)
            if clamped != loop { repairs.append(.loop) }
            state.loop = clamped
        } else {
            repairs.append(.loop)
        }

        if let viewport = file.viewport {
            let clamped = viewport.clamped(to: total)
            if clamped != viewport { repairs.append(.viewport) }
            state.viewport = clamped
        } else {
            repairs.append(.viewport)
        }

        if let playhead = file.playhead {
            let clamped = Swift.max(0, Swift.min(playhead, total))
            if clamped != playhead { repairs.append(.playhead) }
            state.playhead = clamped
        } else {
            repairs.append(.playhead)
        }

        // Reported last so it reads as the summary it is. A mismatch does not
        // stop anything above from applying — the values are already clamped
        // into the recording that is actually loaded — but the user is told,
        // because a loop that has moved is exactly the silent loss spec §7
        // names.
        if let recorded = file.track, !recorded.matches(sampleRate: sampleRate, frameCount: total) {
            repairs.append(.trackIdentity)
        }

        return SessionRestoration(state: state, repairs: repairs)
    }
}

/// The result of reading an untrusted payload: what to run on, and what had to
/// be changed to get there.
public struct SessionRestoration: Equatable, Sendable {
    public var state: SessionState
    /// Empty when the file was read exactly as written. Anything in here is
    /// worth telling the user about, because it means the sidecar on disk did
    /// not describe the session they are about to get.
    public var repairs: [SessionRepair]

    public init(state: SessionState, repairs: [SessionRepair]) {
        self.state = state
        self.repairs = repairs
    }

    public var isPristine: Bool { repairs.isEmpty }
}

/// One thing a sidecar could not be trusted about.
public enum SessionRepair: String, Sendable, Hashable, CaseIterable {
    case schemaVersion
    case speed
    case loop
    case viewport
    case playhead
    case trackIdentity

    /// A noun phrase that completes "Artscribe could not use …", so the caller
    /// composes one sentence rather than concatenating fragments.
    public var label: String {
        switch self {
        case .schemaVersion: return "its format version"
        case .speed: return "the speed"
        case .loop: return "the loop points"
        case .viewport: return "the zoom"
        case .playhead: return "the playhead"
        case .trackIdentity: return "the recording it was written for"
        }
    }
}

/// Which recording a set of frame numbers belongs to.
public struct TrackIdentity: Equatable, Sendable, Codable {
    public var sampleRate: Double
    public var frameCount: FrameIndex

    public init(sampleRate: Double = 0, frameCount: FrameIndex = 0) {
        self.sampleRate = sampleRate.isFinite ? Swift.max(0, sampleRate) : 0
        self.frameCount = Swift.max(0, frameCount)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sampleRate: try container.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 0,
            frameCount: try container.decodeIfPresent(FrameIndex.self, forKey: .frameCount) ?? 0)
    }

    /// Half a frame of tolerance on the rate, because a rate is a `Double` that
    /// has been through JSON; exact on the length, because a length is a count.
    public func matches(sampleRate: Double, frameCount: FrameIndex) -> Bool {
        guard self.frameCount == frameCount else { return false }
        // A file written before the rate was recorded (or with it hand-deleted)
        // says 0, which is "unknown" rather than "wrong".
        guard self.sampleRate > 0, sampleRate > 0 else { return true }
        return abs(self.sampleRate - sampleRate) < 0.5
    }
}

/// The persisted half of `Viewport`: where the window sits and how far it is
/// zoomed in.
///
/// `Viewport`'s other two properties are deliberately absent. `totalFrames`
/// belongs to the recording and `widthPixels` to the window the user happens to
/// have open, so persisting either would restore a viewport that describes some
/// other machine's screen.
public struct ViewportState: Equatable, Sendable, Codable {
    /// Non-positive or non-finite means **fit the whole file**, which is also
    /// what a viewport that was never zoomed reports. See `Viewport.restore`.
    public var framesPerPixel: Double
    public var startFrame: FrameIndex

    /// The whole file, from the beginning.
    public static let fitted = ViewportState(startFrame: 0, framesPerPixel: 0)

    public init(startFrame: FrameIndex, framesPerPixel: Double) {
        self.startFrame = startFrame
        self.framesPerPixel = framesPerPixel
    }

    private enum CodingKeys: String, CodingKey {
        case startFrame
        case framesPerPixel
    }

    /// Validating for the same reason `SpeedState` and `VolumeState` are: a
    /// hand-edited sidecar must not be able to hand the zoom maths a NaN, which
    /// propagates into every pixel-to-frame conversion in the app.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(FrameIndex.self, forKey: .startFrame)
        let fpp = try container.decode(Double.self, forKey: .framesPerPixel)
        self.startFrame = start
        self.framesPerPixel = fpp.isFinite ? fpp : 0
    }

    /// The same viewport with every value inside the recording it will be
    /// applied to. `startFrame` may sit exactly at the end, matching
    /// `Viewport`'s own inclusive upper bound.
    public func clamped(to totalFrames: FrameIndex) -> ViewportState {
        let total = Swift.max(0, totalFrames)
        return ViewportState(
            startFrame: Swift.max(0, Swift.min(startFrame, total)),
            framesPerPixel: framesPerPixel.isFinite && framesPerPixel > 0 ? framesPerPixel : 0)
    }
}

/// The JSON the `.artscribe` sidecar holds.
///
/// Every field is optional on purpose. This is the only type in the project
/// that reads a file a human is invited to edit, so "the key is missing", "the
/// key is a string where a number belongs" and "the file was truncated
/// mid-write" are all ordinary inputs rather than programmer errors. A field
/// that cannot be read becomes `nil` here and a named repair in
/// `SessionState.restoring`; it never throws the whole file away, and it never
/// crashes.
public struct SessionFile: Equatable, Sendable, Codable {
    /// Bumped only when the meaning of an existing key changes. Adding a key
    /// does not need it: an older build ignores what it does not know, and a
    /// newer one reports the field as absent and uses its default.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int?
    public var track: TrackIdentity?
    public var speed: SpeedState?
    /// Absent in sidecars written before pitch existed; absent means "original
    /// key", which is the honest reading rather than damage.
    public var pitch: PitchState?
    public var loop: LoopRegion?
    public var viewport: ViewportState?
    public var playhead: FrameIndex?
    /// Absent in every sidecar written before Task 27, which is exactly why it
    /// is optional: an older file reads as `nil` and takes the default rather
    /// than being reported as damaged.
    public var showTrackMarks: Bool?

    public init(
        schemaVersion: Int? = nil,
        track: TrackIdentity? = nil,
        speed: SpeedState? = nil,
        pitch: PitchState? = nil,
        loop: LoopRegion? = nil,
        viewport: ViewportState? = nil,
        playhead: FrameIndex? = nil,
        showTrackMarks: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.track = track
        self.speed = speed
        self.pitch = pitch
        self.loop = loop
        self.viewport = viewport
        self.playhead = playhead
        self.showTrackMarks = showTrackMarks
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case track
        case speed
        case pitch
        case loop
        case viewport
        case playhead
        case showTrackMarks
    }

    /// `try?` per field, deliberately.
    ///
    /// Each of these sub-decoders is itself validating, so what `try?` swallows
    /// is only the cases they refuse outright — a missing required key, or a
    /// value of the wrong JSON type. Swallowing it *per field* is the whole
    /// point: one mistyped `"loop"` object must not cost the user their speed
    /// and their zoom as well. What was swallowed is not lost, because a `nil`
    /// here becomes a named `SessionRepair` the user is shown.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try? container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        track = try? container.decodeIfPresent(TrackIdentity.self, forKey: .track)
        speed = try? container.decodeIfPresent(SpeedState.self, forKey: .speed)
        pitch = try? container.decodeIfPresent(PitchState.self, forKey: .pitch)
        loop = try? container.decodeIfPresent(LoopRegion.self, forKey: .loop)
        viewport = try? container.decodeIfPresent(ViewportState.self, forKey: .viewport)
        playhead = try? container.decodeIfPresent(FrameIndex.self, forKey: .playhead)
        showTrackMarks = try? container.decodeIfPresent(Bool.self, forKey: .showTrackMarks)
    }
}
