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

    // MARK: - Preferences

    /// Attaches the persistent store and adopts what it holds.
    ///
    /// Called once, from the app shell, and read *here* rather than in `init`
    /// for the reason `attach(nudge:)` records: a `ViewerModel` built by a unit
    /// test stays on the shipped defaults and never reads the user's real
    /// preferences.
    public func attach(interaction settings: InteractionSettings) {
        interactionStore = settings
        let loaded = settings.load()
        if loaded.invertZoomDrag != invertZoomDrag { invertZoomDrag = loaded.invertZoomDrag }
        if loaded.selectionMove != selectionMoveAmounts {
            selectionMoveAmounts = loaded.selectionMove
        }
    }

    /// Settings ▸ *Invert zoom direction*. Applies to both vertical drags — the
    /// ruler's and the lanes' ⌥-drag — and to the scroll-wheel zoom, so one
    /// window never holds two zoom conventions at once.
    public func setInvertZoomDrag(_ inverted: Bool) {
        guard inverted != invertZoomDrag else { return }
        invertZoomDrag = inverted
        saveInteractionPreferences()
    }

    /// From the Settings window. The amount is validated by
    /// `SelectionMoveAmounts`, so a zero, a negative or an absurd value cannot
    /// get in here (spec §8).
    public func setSelectionMoveAmount(_ seconds: Double, for tier: SelectionMoveTier) {
        var next = selectionMoveAmounts
        next[tier] = seconds
        guard next != selectionMoveAmounts else { return }
        selectionMoveAmounts = next
        saveInteractionPreferences()
    }

    /// Settings ▸ Restore Defaults for the move amounts: 250 ms / 2 s.
    public func restoreDefaultSelectionMoveAmounts() {
        guard selectionMoveAmounts != .defaults else { return }
        selectionMoveAmounts = .defaults
        saveInteractionPreferences()
    }

    /// Settings ▸ Restore Defaults. One button for the whole tab, because one
    /// per section is three ways to ask the same question — and because a user
    /// who wants "put it back as it came" should not have to find all of them.
    public func restoreDefaults() {
        restoreDefaultNudgeAmounts()
        restoreDefaultSelectionMoveAmounts()
        setInvertZoomDrag(false)
    }

    /// Whether anything on the Settings tab has been moved off its default,
    /// which is what the button greys out on.
    public var hasNonDefaultPreferences: Bool {
        nudgeAmounts != NudgeAmounts.defaults || selectionMoveAmounts != .defaults
            || invertZoomDrag
    }

    private func saveInteractionPreferences() {
        interactionStore?.save(
            InteractionPreferences(
                invertZoomDrag: invertZoomDrag, selectionMove: selectionMoveAmounts))
    }

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
            seconds: selectionMoveAmounts[tier] * direction.sign, sampleRate: sampleRate)
        let moved = selection.translated(by: delta, within: totalFrames)
        guard moved != selection else { return }
        selection = moved
        // Follow the edge it is travelling towards, so a selection moved off
        // the visible page is not moved blind. Page-flip, like everything else
        // that moves the view (spec §6.1).
        reveal(direction == .backward ? moved.range.start : moved.range.end)
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
            from: next.head, bySeconds: nudgeAmounts[.normal] * direction.sign,
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
