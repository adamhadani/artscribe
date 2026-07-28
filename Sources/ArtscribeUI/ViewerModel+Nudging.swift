import ArtscribeKit

/// The three navigation tiers on the model — spec §6.2's `transport.nudge`
/// actions, and the amounts the Settings window edits.
///
/// Its own extension file rather than more of `ViewerModel+Playback`, which is
/// already at the project's 400-line limit. Everything here goes out through
/// `seek(to:)`, so there is still exactly one place the playhead moves by user
/// action.
extension ViewerModel {

    /// Attaches the persistent store and adopts what it holds.
    ///
    /// Called once, from the app shell. The amounts are read *here* rather than
    /// in `init` so a `ViewerModel` built by a unit test stays on the shipped
    /// defaults and never reads the user's real preferences.
    public func attach(nudge settings: NudgeSettings) {
        nudgeStore = settings
        let loaded = settings.load()
        if loaded != nudgeAmounts { nudgeAmounts = loaded }
    }

    /// From the Settings window. The amount is validated by `NudgeAmounts`, so a
    /// zero, a negative or an absurd value cannot get in here (spec §8).
    public func setNudgeAmount(_ seconds: Double, for tier: NudgeTier) {
        var next = nudgeAmounts
        next[tier] = seconds
        applyNudgeAmounts(next)
    }

    /// Settings ▸ Restore Defaults: 50 ms / 2 s / 10 s.
    public func restoreDefaultNudgeAmounts() {
        applyNudgeAmounts(.defaults)
    }

    private func applyNudgeAmounts(_ next: NudgeAmounts) {
        guard next != nudgeAmounts else { return }
        nudgeAmounts = next
        nudgeStore?.save(next)
    }

    /// Moves the playhead by one tier's amount.
    ///
    /// Works stopped or playing, and does not restart audio either way: the only
    /// thing it can push is `.seek`, which the engine applies in place. There is
    /// deliberately **no** `.setPlaying` here, so a nudge while paused stays
    /// paused and a nudge while playing keeps playing.
    ///
    /// A nudge is free to leave an active loop region, matching Transcribe!: the
    /// tier you reach for when the phrase starts a beat earlier than you set the
    /// in point is precisely the one that has to be able to cross it. `F`
    /// (`restartLoop`) is one key away when you want to be back inside it, and
    /// the loop keeps looping the moment playback next reaches its out point.
    public func nudge(_ tier: NudgeTier, direction: NudgeDirection) {
        guard hasTrack else { return }
        let target = NudgeStepping.target(
            from: playhead, bySeconds: nudgeAmounts[tier] * direction.sign,
            sampleRate: sampleRate, totalFrames: totalFrames)
        // Already there — at either end of the file, or with an unusable sample
        // rate. Not merely wasteful: `.seek` is one of the two paths that reset
        // the stretcher (see CLAUDE.md on looping), so a redundant seek on every
        // press at the end of the file would click.
        guard target != playhead else { return }
        seek(to: target)
        // The playhead is what you are listening to, so the view follows it —
        // page-flip, through exactly the same rule that follows playback, so a
        // nudge inside the visible page moves nothing at all.
        autoScroll()
    }
}
