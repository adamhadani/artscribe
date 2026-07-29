import ArtscribeKit

/// The three navigation tiers on the model — spec §6.2's `transport.nudge`
/// actions, and the amounts the Settings window edits.
///
/// Its own extension file rather than more of `ViewerModel+Playback`, which is
/// already at the project's 400-line limit. Everything here goes out through
/// `seek(to:)`, so there is still exactly one place the playhead moves by user
/// action.
extension ViewerModel {

    /// Moves the playhead by one tier's amount.
    ///
    /// Works stopped or playing, and does not restart audio either way: the only
    /// thing it can push is `.seek`, which the engine applies in place. There is
    /// deliberately **no** `.setPlaying` here, so a nudge while paused stays
    /// paused and a nudge while playing keeps playing.
    ///
    /// A nudge is free to leave an active loop region, matching Transcribe!: the
    /// tier you reach for when the phrase starts a beat earlier than you set the
    /// in point is precisely the one that has to be able to cross it. Since Task
    /// 24 the engine honours where it lands, and the loop captures on arrival: a
    /// nudge back **before** the in point plays on and is caught at the out point,
    /// and one **past** the out point plays to the end of the file. `F`
    /// (`restartLoop`) is one key away either way.
    public func nudge(_ tier: NudgeTier, direction: NudgeDirection) {
        guard hasTrack else { return }
        let target = NudgeStepping.target(
            from: playhead, bySeconds: prefs.nudgeAmounts[tier] * direction.sign,
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
