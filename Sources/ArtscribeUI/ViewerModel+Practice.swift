import ArtscribeKit

/// **The Practice hub's behaviour**, on the model rather than in the window.
///
/// The window is a view over this and nothing more: it draws `ramp`, edits
/// `ramp.schedule`, and presses `startRamp()` / `stopRamp()`. Everything that
/// could be wrong is here, where a test can reach it without a screen — which is
/// the same reason the loop and the transport live on the model rather than in
/// `DocumentView`.
///
/// ## The ramp drives the actions that already exist
///
/// It sets the speed through `setSpeedPreset`, which is the `1`–`4` keys' own
/// path — quantise, clamp, then a single `PlaybackCommand.setTimeRatio` the
/// engine applies on its next render quantum with no reset and therefore no
/// click (spec §5.1). It enables looping through `toggleLoop()`, moves to the in
/// point through `restartLoop()`, and starts the transport through `play()`.
/// There is no second implementation of any of that here, and there must never
/// be: a ramp that pushed its own commands would be a second way to reach the
/// render thread, which spec §5 does not have.
///
/// ## And it advances on the loop, not on a clock
///
/// See `LoopWrapTracker` for why a timer is wrong here and what a wrap is
/// measured as. The event arrives from `tickPlayback`'s existing poll of the
/// engine's audible position; nothing new crosses the thread boundary.
extension ViewerModel {

    /// Whether a ramp could be started right now.
    ///
    /// A loop **region** is what is required, not an enabled loop: starting the
    /// ramp switches looping on if it is off, because a region that exists and
    /// is merely switched off is one keystroke from being what you meant, and
    /// refusing it would be the window silently doing nothing — the exact
    /// failure the empty state exists to prevent.
    public var canRamp: Bool { hasTrack && loop.range.count > 0 }

    /// Hands the model the persisted schedule, and somewhere to write it back.
    /// Optional, like every other `attach`: a unit test builds a model with no
    /// store and never touches `UserDefaults`.
    public func attach(practice: PracticeSettings) {
        practiceStore = practice
        ramp.schedule = practice.load()
    }

    // MARK: - Editing the schedule

    /// Replaces the plan. Refused while a ramp is running: a repetition count
    /// that shrinks under a running index is a question with no good answer, and
    /// the window disables the fields for the same reason rather than leaving a
    /// control that silently does nothing.
    public func setRampSchedule(_ schedule: RampSchedule) {
        guard !ramp.isRunning else { return }
        guard schedule != ramp.schedule else { return }
        ramp.schedule = schedule
        practiceStore?.save(ramp.schedule)
    }

    public func setRampStartRatio(_ ratio: Double) {
        var schedule = ramp.schedule
        schedule.setStartRatio(ratio)
        setRampSchedule(schedule)
    }

    public func setRampEndRatio(_ ratio: Double) {
        var schedule = ramp.schedule
        schedule.setEndRatio(ratio)
        setRampSchedule(schedule)
    }

    public func setRampRepetitions(_ count: Int) {
        var schedule = ramp.schedule
        schedule.setRepetitions(count)
        setRampSchedule(schedule)
    }

    // MARK: - Running it

    /// **Start.** Enables the loop if it is off, goes to its in point, sets the
    /// first repetition's speed, and plays.
    ///
    /// Every one of those is deliberate. Going to the in point is what makes the
    /// first repetition a whole one — starting a ramp two thirds of the way
    /// through the phrase would put the first speed change a third of a
    /// repetition early and every one after it out by the same amount. Playing
    /// is what stops a Start button from doing nothing audible; the ramp is a
    /// practice tool, and the thing you pressed it for is to hear the passage.
    public func startRamp() {
        guard canRamp else { return }
        if !loop.isEnabled { toggleLoop() }
        // Also clears the wrap tracker's baseline, since it seeks — so the jump
        // to the in point is not itself counted as the first repetition.
        restartLoop()
        ramp.start()
        setSpeedPreset(ramp.currentRatio)
        if !isPlaying { play() }
    }

    /// **Stop**, wherever the ramp got to, including from `.complete`.
    ///
    /// It leaves the speed and the transport exactly where they are. Snapping
    /// back to 100% would undo the tempo you pressed stop in order to keep
    /// working at, and pausing would be the ramp taking over a transport it does
    /// not own — the same reasoning that decides what happens at the end of a
    /// ramp, for which see `SpeedRamp`.
    public func stopRamp() {
        guard !ramp.isIdle else { return }
        ramp.stop()
    }

    /// What the menu item and `⌥R` do. A completed ramp restarts rather than
    /// clearing, because "again, from the top" is what you want next.
    public func toggleRamp() {
        if ramp.isRunning {
            stopRamp()
        } else {
            startRamp()
        }
    }

    // MARK: - The event

    /// One polled playhead position, from `tickPlayback`.
    ///
    /// Internal rather than private so the tests can drive the ramp through the
    /// same door the display link uses — a unit test has no audio graph, and a
    /// ramp whose only test path bypassed the wrap detection would prove nothing
    /// about the thing that is actually hard here.
    func notePlayhead(_ frame: FrameIndex) {
        guard wrapTracker.observe(playhead: frame, loop: loop) else { return }
        loopDidWrap()
    }

    /// The loop went round once.
    private func loopDidWrap() {
        guard ramp.isRunning else { return }
        // `nil` means the ramp has just completed, and a completed ramp holds
        // the speed it finished on. Not an error, and not a silence: `ramp.phase`
        // is `.complete` and the window says so.
        guard let ratio = ramp.advance() else { return }
        setSpeedPreset(ratio)
    }
}
