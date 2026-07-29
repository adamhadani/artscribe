import ArtscribeKit

/// Where a `Space` resume starts from — spec §6.2's `transport.preroll`.
///
/// **The workflow it exists for.** You stop on a note. To hear that note in
/// context you cannot start on it: you have to start slightly *before* it, hear
/// what leads into it, and let it arrive. Every transcriber does this by hand,
/// with a nudge back before every resume; the preroll is that nudge, folded into
/// the key that was going to be pressed anyway.
///
/// Pure and outside `ViewerModel` for the reason this project keeps repeating:
/// the interesting behaviour is all at the boundaries — off, the file start, an
/// active loop's in point — and a boundary is far easier to test than to
/// observe. The end-of-file boundary is the one exception and lives on the model
/// (`ViewerModel.prerollTarget`), because it is not arithmetic: it is a question
/// about what `play()` is going to do next.
public enum Preroll {

    /// Two seconds: about a bar at a moderate tempo, which is enough lead-in to
    /// place a note and short enough not to feel like a rewind.
    public static let defaultSeconds = 2.0

    /// **Zero is allowed, and means off.** This is the one place the amounts in
    /// this app disagree about their floor, and deliberately: `NudgeAmounts`
    /// forbids zero because a nudge of zero is a key that looks healthy and does
    /// nothing, whereas a preroll of zero is a coherent request — "resume
    /// exactly where I stopped" — and is precisely how the app behaved before
    /// the feature existed. A user who types 0 has turned it off, not broken it.
    public static let minimumSeconds = 0.0

    /// `NudgeAmounts`' ceiling, so there is one definition of "an amount of time
    /// this app will accept".
    public static let maximumSeconds = NudgeAmounts.maximumSeconds

    /// Clamps into the allowed range; a value that is not a number at all falls
    /// back to the default rather than to an arbitrary end of the range.
    ///
    /// Every route in goes through here — the Settings field, the stored
    /// preference, Restore Defaults — for the same reason `NudgeAmounts` puts
    /// its check in the subscript: spec §8 forbids degrading silently, and
    /// storage is not a trusted source.
    public static func validated(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return defaultSeconds }
        return Swift.min(Swift.max(seconds, minimumSeconds), maximumSeconds)
    }

    /// The frame a resume should start from: `playhead − seconds`, clamped.
    ///
    /// Two floors, in order:
    ///
    /// 1. **The file start.** There is nothing before frame 0 to roll back into.
    /// 2. **An active loop's in point**, whenever the playhead is inside that
    ///    loop. See below — it is the one judgement call in this type.
    ///
    /// **Why the loop floors it.** Task 24 established that the engine honours
    /// an explicit seek and that a loop captures on *arrival*, not on entry. So
    /// a preroll landing before the in point would not be pulled back: it would
    /// play the lead-in, run into the region, and be caught at the out point —
    /// after which the lead-in is never heard again. A loop is the user's
    /// explicit statement of which passage they are working on, and a resume
    /// that steps outside it exactly once, on the first repetition only, is the
    /// "this app follows two competing rules" complaint that Task 22 existed to
    /// kill. Flooring at the in point keeps every resume inside the passage, and
    /// costs nothing: `⌥Z` and a nudged loop edge are both one key away when
    /// what you actually want is more lead-in.
    ///
    /// A playhead **outside** an active loop is not being governed by it — the
    /// user nudged out or clicked away — so it contributes no floor there.
    ///
    /// - Parameter seconds: the preroll amount, unsigned. Validated here too, so
    ///   a caller holding a value from anywhere cannot roll *forwards*.
    public static func target(
        from playhead: FrameIndex, seconds: Double, sampleRate: Double,
        totalFrames: FrameIndex, loop: LoopRegion
    ) -> FrameIndex {
        guard totalFrames > 0 else { return 0 }
        let amount = validated(seconds)
        guard amount > 0 else { return Swift.max(0, Swift.min(playhead, totalFrames)) }
        // `NudgeStepping` already saturates, clamps to `[0, totalFrames]` and
        // refuses an unusable sample rate — a preroll is a nudge backwards that
        // the user did not have to ask for, so it is the same arithmetic.
        let rolled = NudgeStepping.target(
            from: playhead, bySeconds: -amount, sampleRate: sampleRate,
            totalFrames: totalFrames)
        guard loop.isActive, loop.range.contains(playhead) else { return rolled }
        return Swift.max(rolled, loop.range.start)
    }
}
