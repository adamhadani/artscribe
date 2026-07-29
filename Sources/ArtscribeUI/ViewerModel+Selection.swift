import ArtscribeKit

/// Moving and extending the selection, and the interaction preferences that
/// govern them and the zoom drag — spec §6.2's `selection.move` and
/// `selection.extend` actions.
///
/// Its own extension file rather than more of `ViewerModel+Interaction`, which
/// already holds the pointer state machine. The clamping arithmetic is not
/// here: it is `Selection.translated(by:within:)` in `ArtscribeKit`, where it
/// can be tested at both file boundaries without a model.
extension ViewerModel {

    // MARK: - Moving the whole selection

    /// Slides the whole selection along the timeline, both edges together.
    ///
    /// The playhead is deliberately left where it is: this moves the passage
    /// you are looking at, not the position you are listening from, and a seek
    /// is one of the two things that reset the stretcher (see CLAUDE.md on
    /// looping). The loop is left alone too — `G` is one key away when you want
    /// the moved selection to become it.
    ///
    /// Clamped as a whole at both ends of the file, so a selection pushed
    /// against an end stops there with its length intact rather than shrinking
    /// or inverting. That is `Selection.translated(by:within:)`'s job.
    public func moveSelection(_ tier: SelectionMoveTier, direction: NudgeDirection) {
        guard hasTrack, !selection.isEmpty else { return }
        let delta = NudgeStepping.frames(
            seconds: prefs.selectionMoveAmounts[tier] * direction.sign, sampleRate: sampleRate)
        let moved = selection.translated(by: delta, within: totalFrames)
        guard moved != selection else { return }
        selection = moved
        // Follow the edge it is travelling towards, so a selection moved off
        // the visible page is not moved blind. Page-flip, like everything else
        // that moves the view (spec §6.1).
        reveal(direction == .backward ? moved.range.start : moved.range.end)
    }

    // MARK: - Moving the loop

    /// Slides one of the loop's edges, or the whole region — spec §6.2's
    /// `loop.move` actions.
    ///
    /// **It shares the selection's amounts** (`selectionMoveAmounts`) rather than
    /// adding a third and fourth preference. "Nudge a region into place" is one
    /// job with one pair of sizes — a touch and a lot — and it is the same job
    /// whether the region is the passage you are looking at or the one you are
    /// hearing. Two more Settings rows would be two more numbers to keep in
    /// agreement, and a user who tuned the selection step and then found the loop
    /// step ignoring it would be right to call that a bug.
    ///
    /// The playhead is deliberately left alone, for the reason `moveSelection`
    /// records: this moves what you are listening *to*, not where you are
    /// listening *from*, and a seek is one of the two things that reset the
    /// stretcher (CLAUDE.md on looping). Going out through `applyLoop` — the
    /// app's one `PlaybackCommand.setLoop` path — is what makes a move while
    /// playing take effect without a click: the engine adopts the new boundary on
    /// its next feed and never resets there (spec §5.1).
    public func moveLoop(
        _ target: LoopMoveTarget, _ tier: SelectionMoveTier, direction: NudgeDirection
    ) {
        guard hasTrack, !loop.range.isEmpty else { return }
        let moved = LoopMoving.moved(
            loop, target: target, bySeconds: prefs.selectionMoveAmounts[tier] * direction.sign,
            sampleRate: sampleRate, totalFrames: totalFrames)
        guard moved != loop else { return }
        applyLoop(moved)
        // Follow the edge that moved, so a loop nudged off the visible page is
        // not nudged blind. Page-flip, like everything else that moves the view
        // (spec §6.1).
        reveal(revealTarget(for: target, in: moved, direction: direction))
    }

    /// The frame worth having on screen after a loop move: the edge that moved,
    /// and for a whole-loop move the edge it is travelling towards.
    private func revealTarget(
        for target: LoopMoveTarget, in moved: LoopRegion, direction: NudgeDirection
    ) -> FrameIndex {
        switch target {
        case .inPoint: return moved.range.start
        case .outPoint: return moved.range.end
        case .whole: return direction == .backward ? moved.range.start : moved.range.end
        }
    }

    /// `⇧←` / `⇧→` — spec §6.2's `selection.extendLeft` / `.extendRight`.
    ///
    /// The anchor stays put and the head moves, which is the same shape as a
    /// ⇧-drag in the lanes. It moves by the **normal nudge amount**: the tier
    /// `←`/`→` already move the playhead by, so the two arrow gestures agree
    /// about how far one press goes, and Settings edits both at once.
    ///
    /// With nothing selected the anchor is dropped at the playhead first, so
    /// the key does something useful from a bare cursor rather than nothing.
    public func extendSelection(_ direction: NudgeDirection) {
        guard hasTrack else { return }
        var next = selection
        if next.isEmpty { next.begin(at: playhead) }
        let head = NudgeStepping.target(
            from: next.head, bySeconds: prefs.nudgeAmounts[.normal] * direction.sign,
            sampleRate: sampleRate, totalFrames: totalFrames)
        next.extend(to: head)
        guard next != selection else { return }
        selection = next
        reveal(head)
    }

    /// Brings `frame` onto the visible page if it is off it, and holds still if
    /// it is not. The page-flip rule of `AutoScroll`, asked about an arbitrary
    /// frame rather than about the playhead.
    func reveal(_ frame: FrameIndex) {
        guard let start = AutoScroll.pageStart(revealing: frame, viewport: viewport) else {
            return
        }
        let delta = Double(start - viewport.startFrame) / viewport.framesPerPixel
        guard delta.isFinite, abs(delta) < Double(Int.max) else { return }
        scroll(byPoints: Int(delta.rounded()))
    }
}
