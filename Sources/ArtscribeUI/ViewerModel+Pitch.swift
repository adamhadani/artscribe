import ArtscribeKit

/// Transposition on the model — spec-level "pitch, independent of speed".
///
/// Every path funnels through `applyPitch`, so there is exactly one place a
/// pitch reaches the render thread, matching how `applySpeed` and `applyLoop`
/// are the single writers for their own state.
extension ViewerModel {

    /// A semitone, the default step. What `[` and `]` move by.
    public static let semitoneStep = PitchState.centsPerSemitone
    /// The fine step, for the ⇧ variants: one cent, the finest audible unit.
    public static let centStep = 1

    /// From the slider, and from the Settings-style numeric field.
    public func setPitch(cents: Int) {
        var next = pitch
        next.setCents(cents)
        applyPitch(next)
    }

    /// `]` / `[`, and their ⇧ variants.
    public func adjustPitch(byCents delta: Int) {
        guard hasTrack else { return }
        var next = pitch
        // `adjust` reports whether it moved, so holding a key at the end of the
        // range does not push a redundant command at the render thread 62 times
        // a second.
        guard next.adjust(byCents: delta) else { return }
        applyPitch(next)
    }

    /// `⌥\`, and Playback ▸ Reset Pitch.
    public func resetPitch() {
        guard hasTrack else { return }
        var next = pitch
        next.reset()
        applyPitch(next)
    }

    /// The one place pitch changes.
    func applyPitch(_ next: PitchState) {
        guard next != pitch else { return }
        pitch = next
        session?.push(.setPitchScale(next.scale))
        markSessionEdited()
    }

    /// How the transport bar and the status bar say it: `+3` semitones reads as
    /// `+3`, and three and a half as `+3 +50¢`. Zero says nothing, because an
    /// untransposed track is the normal case and a badge for it is noise.
    public var pitchLabel: String {
        guard pitch.isAltered else { return "" }
        let semitones = pitch.semitones
        let remainder = pitch.centsRemainder
        let sign = pitch.cents > 0 ? "+" : "−"
        let magnitude = abs(semitones)
        if remainder == 0 { return "\(sign)\(magnitude)" }
        if semitones == 0 { return "\(sign)\(abs(remainder))¢" }
        return "\(sign)\(magnitude) \(sign)\(abs(remainder))¢"
    }
}
