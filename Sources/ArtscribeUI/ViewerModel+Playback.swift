import ArtscribeKit
import AudioDecode
import Foundation
import Playback

/// The transport, speed and loop half of the model: the only place in the app
/// that talks to `PlaybackEngine`.
///
/// The direction of every wire here is deliberate and load-bearing (spec §5):
///
/// - **Down**, main actor → render thread: `PlaybackCommand`s pushed into
///   `CommandRing`. Nothing else.
/// - **Up**, render thread → main actor: `PlaybackEngine.currentFrame` and the
///   degradation counters, **polled** on a display link. The audio thread never
///   pushes, never calls back, and never touches this model.
///
/// Every action is guarded rather than precondition-checked, because the menu bar
/// can invoke any of them at any time, including with no track loaded.
extension ViewerModel {

    // MARK: - Session lifetime

    /// Called by the window so the model can route audio and report device
    /// changes. Optional: unit tests build a model with no device controller and
    /// no audio graph at all.
    public func attach(devices: OutputDeviceController) {
        self.devices = devices
        if let session { devices.attach(output: session.output) }
    }

    /// Builds the audio graph for a freshly loaded track and starts the clock.
    ///
    /// A failure here is surfaced as an inline banner and nothing else: the
    /// waveform, zoom, and selection all still work without an audio device, and
    /// throwing away a decoded file because the speakers are busy would be a far
    /// worse answer than saying so.
    func openSession(for audio: DecodedAudio) {
        do {
            let session = try PlaybackSession(audio: audio, stretchEngine: speed.engine)
            self.session = session
            devices?.attach(output: session.output)
            try session.start()
            session.push(.setTimeRatio(speed.timeRatio))
            // The graph is new, so it is at its own default gain until told
            // otherwise — including after an engine rebuild.
            session.output.setVolume(volume.amplitude)
            isResampling = session.output.needsSampleRateConversion()
            startClock()
        } catch {
            session = nil
            isResampling = false
            playbackNotice =
                "Audio output is unavailable: \(TrackLoader.message(for: error)) "
                + "The waveform is still usable, but nothing will play."
        }
    }

    /// Stops the audio graph and the clock. Public so the window can call it when
    /// it goes away.
    public func teardownPlayback() {
        teardownSession()
    }

    func teardownSession() {
        clock.stop()
        session?.stop()
        session = nil
        devices?.attach(output: nil)
        transport = TransportLatch()
        degradation = DegradationCounts()
        isResampling = false
        lastRateCheck = 0
        wrapTracker.reset()
    }

    private func startClock() {
        clock.start { [weak self] in
            self?.tickPlayback(now: ProcessInfo.processInfo.systemUptime)
        }
        if let notice = clock.fallbackNotice { playbackNotice = notice }
    }

    public func dismissPlaybackNotice() {
        playbackNotice = nil
    }

    /// A device disappearing, or a refused switch (spec §8).
    ///
    /// Read straight from the controller rather than copied into
    /// `playbackNotice` on a poll, because it must be visible **whether or not a
    /// track is loaded** — the display link only runs while there is a session,
    /// and a controller notice raised with no track would otherwise sit unread
    /// inside the Playback menu, which is exactly the state the previous version
    /// left it in. `OutputDeviceController` is `@Observable`, so a view reading
    /// this tracks it with no polling at all.
    public var deviceNotice: String? { devices?.notice }

    public func dismissDeviceNotice() {
        devices?.clearNotice()
    }

    // MARK: - The poll
    //
    // One tick per display refresh. This is the entire render-thread → UI path.

    func tickPlayback(now: Double) {
        guard let session else { return }
        pollDegradation(session)
        // Once a second, not once a frame: switching output device from the menu
        // succeeds silently, and the new device may run at a different rate. The
        // query allocates an `AVAudioFormat`, so it is deliberately not on the
        // per-frame path.
        if now - lastRateCheck > 1 {
            lastRateCheck = now
            let resampling = session.output.needsSampleRateConversion()
            if resampling != isResampling { isResampling = resampling }
        }

        switch pollTransport(enginePlaying: session.engine.isPlaying, now: now) {
        case .unchanged, .started:
            break
        case .finished:
            // The engine ran out of source and cleared its own flag. Park the
            // playhead on the end so the next play knows to rewind (see
            // `TransportLatch.rewindTarget`).
            reachedEnd = true
            playhead = totalFrames
        case .neverStarted:
            playbackNotice =
                "Playback did not start: the audio render thread never reported playing. "
                + "Check the output device in the Playback menu."
        }

        guard transport.isPlaying else { return }
        let frame = PlayheadSync.audibleFrame(
            engineFrame: session.engine.currentFrame,
            outputLatency: session.output.outputLatency,
            sampleRate: sampleRate,
            speedRatio: speed.ratio)
        // Compared before assigning: `@Observable` invalidates on every write,
        // and a stationary playhead must not redraw the window sixty times a
        // second while the engine is stalled or paused mid-drain.
        if frame != playhead { playhead = frame }
        // The practice ramp's only clock: a loop wrap is read out of this same
        // position stream rather than timed (`LoopWrapTracker` says why a timer
        // cannot work here). Unconditional rather than gated on a running ramp,
        // so the baseline is always current.
        notePlayhead(frame)
        autoScroll()
    }

    /// Reconciles the latch with the engine, writing it back **only when it
    /// actually moved** — which is the whole reason this method exists.
    ///
    /// `TransportLatch.poll` is `mutating`, so polling the stored `transport` in
    /// place goes through the `@Observable` macro's `_modify`, which notifies
    /// unconditionally: a poll that decided nothing still counted as a change.
    /// Measured with a track loaded and *paused*, an observer of `isPlaying` was
    /// invalidated 62 times a second, forever. That is what hid the Output Device
    /// submenu — SwiftUI reapplied the Playback menu's items on every one of
    /// those, and a menu item reapplied at 62 Hz never survives long enough for
    /// AppKit's submenu-open delay to elapse, so hovering the row opened nothing.
    /// A/B against this exact line: 62 invalidations/s and no submenu; 0 and it
    /// opens, playing or paused. See CLAUDE.md, "Observation notifies on
    /// `_modify` whether or not the value changed".
    func pollTransport(enginePlaying: Bool, now: Double) -> TransportOutcome {
        var latch = transport
        let outcome = latch.poll(enginePlaying: enginePlaying, now: now)
        if latch != transport { transport = latch }
        return outcome
    }

    /// Consumes the counters Task 8 and Task 9 publish. A counter nobody reads is
    /// only half a fix for silent degradation — and because the engine
    /// deliberately stays in the playing state across a stall so that a transient
    /// one can recover, an unsurfaced permanent stall presents to the user as
    /// "playing, playhead frozen, silence, forever".
    private func pollDegradation(_ session: PlaybackSession) {
        let counts = DegradationCounts(
            stalls: session.engine.renderStallCount,
            rejectedCommands: session.engine.rejectedCommandCount,
            bufferLayoutMismatches: session.output.renderLayoutMismatchCount,
            droppedCommands: session.droppedCommands)
        if counts != degradation {
            degradation = counts
            if let banner = counts.banner { playbackNotice = banner }
        }
        // Notices are cleared as they are taken so a second, different one can
        // still be seen; the banner itself is only dismissed by the user. Both
        // sources mean the graph was re-negotiated, so the resampling readout is
        // no longer trustworthy either.
        if let notice = session.output.notice {
            playbackNotice = notice
            session.output.clearNotice()
            isResampling = session.output.needsSampleRateConversion()
        }
    }

    /// Internal, not private: a nudge follows the playhead through this as well.
    func autoScroll() {
        guard let start = AutoScroll.pageStart(playhead: playhead, viewport: viewport, loop: loop)
        else { return }
        let delta = Double(start - viewport.startFrame) / viewport.framesPerPixel
        guard delta.isFinite, abs(delta) < Double(Int.max) else { return }
        scroll(byPoints: Int(delta.rounded()))
    }

    // MARK: - Transport
    //
    // `togglePlayPause` — what `Space` does — is in `ViewerModel+Preroll`.

    public func play() {
        guard hasTrack else { return }
        guard let session else {
            playbackNotice =
                "There is no audio output, so nothing can play. "
                + "Choose a device from the Playback menu, or reopen the file."
            return
        }
        // Trap: at end of file with no loop, `.setPlaying(true)` makes the engine
        // restart the stream, immediately re-finalise it and clear the playing
        // flag inside one render call — the button flickers and nothing is heard.
        let rewind = TransportLatch.rewindTarget(
            playhead: playhead, totalFrames: totalFrames, reachedEnd: reachedEnd,
            loopActive: loop.isActive,
            selectionStart: selection.isEmpty ? nil : selection.range.start)
        if let rewind { seek(to: rewind) }
        do {
            try session.start()
        } catch {
            playbackNotice = "Could not start audio output: \(TrackLoader.message(for: error))"
            return
        }
        session.push(.setPlaying(true))
        transport.request(true, now: ProcessInfo.processInfo.systemUptime)
    }

    /// Halts and leaves the playhead where it is.
    public func pause() {
        session?.push(.setPlaying(false))
        transport.request(false, now: ProcessInfo.processInfo.systemUptime)
    }

    /// `⇧Space` (`Return` until Task 18; the bare `Space` for the length of Task
    /// 28's swap, reverted in Task 29). To the selection start, else the loop's
    /// in point, else the file start — and plays from there. The transcriber's
    /// second-most-used key, because it is how you hear the same phrase again.
    ///
    /// **No preroll**: that applies to resuming from a position the user did
    /// not choose, and this one they did — by selecting, or by setting a loop.
    /// Rolling back before it would leave the passage the key names.
    public func playFromStart() {
        guard hasTrack else { return }
        returnToStart()
        play()
    }

    /// The seek half of `⇧Space`, without playing, and bound on its own as well —
    /// which is why the precedence lives here rather than in `playFromStart`. The
    /// name predates the rebind.
    ///
    /// See `PlaybackStart` for the rule and for why an *active* loop is the one
    /// that counts.
    public func returnToStart() {
        guard hasTrack else { return }
        seek(to: PlaybackStart.target(selection: selection, loop: loop))
    }

    /// The single place the playhead moves by user action. Both halves matter:
    /// the model's own position (so the view is right immediately) and the
    /// command (so the engine follows).
    public func seek(to frame: FrameIndex) {
        guard hasTrack else { return }
        let target = Swift.max(0, Swift.min(frame, totalFrames))
        playhead = target
        // A deliberate jump is shaped exactly like a loop wrap and is not one:
        // `F`, or a nudge back into the loop, must not count as a repetition of
        // the practice ramp. Dropped here, at the single path every user seek
        // takes, so the detector needs no opinion about seeks.
        wrapTracker.reset()
        reachedEnd = target >= totalFrames
        session?.push(.seek(target))
    }

    // MARK: - Speed

    public func slower(fine isFine: Bool) {
        applySpeed(
            SpeedStepping.stepped(speed, by: -(isFine ? SpeedStepping.fine : SpeedStepping.coarse)))
    }

    public func faster(fine isFine: Bool) {
        applySpeed(
            SpeedStepping.stepped(speed, by: isFine ? SpeedStepping.fine : SpeedStepping.coarse))
    }

    /// **Set the speed to a given ratio**, quantised and clamped. Named after
    /// the `1`–`4` keys, its first caller; it is the general path, and Task 21's
    /// practice ramp is its second caller for exactly that reason — a ramp with
    /// its own `setTimeRatio` would be a second way to reach the render thread.
    public func setSpeedPreset(_ ratio: Double) {
        var next = speed
        next.setRatio(SpeedStepping.quantise(ratio))
        applySpeed(next)
    }

    /// `⌥E`. Rubber Band's engine is fixed at construction, and `PlaybackCommand`
    /// deliberately carries only POD payloads, so a running stretcher cannot be
    /// swapped through the ring. The graph is rebuilt instead, off the render
    /// thread, and the position, speed, loop and transport state are restored —
    /// which is audible as a short gap, and is the honest cost of the switch.
    public func toggleStretchEngine() {
        var next = speed
        next.engine = speed.engine == .studio ? .fast : .studio
        applySpeed(next)
    }

    private func applySpeed(_ next: SpeedState) {
        guard next != speed else { return }
        let enginesDiffer = next.engine != speed.engine
        speed = next
        // Before the engine-rebuild branch, not after it: `⌥E` changes the
        // active engine, which spec §7 persists, and marking only the ratio
        // path would leave an engine switch out of the sidecar and out of the
        // close prompt.
        markSessionEdited()
        guard !enginesDiffer else {
            rebuildSession()
            return
        }
        // Applied on the next render quantum, with no reset and therefore no
        // click: `PlaybackEngine` only re-scales its pending-output accounting.
        session?.push(.setTimeRatio(speed.timeRatio))
    }

    private func rebuildSession() {
        guard let audio else { return }
        let wasPlaying = transport.isPlaying
        let position = playhead
        teardownSession()
        openSession(for: audio)
        guard session != nil else { return }
        session?.push(.setLoop(loop.range, loop.isEnabled))
        seek(to: position)
        if wasPlaying { play() }
    }

    // MARK: - Loop

    public func setLoopIn() {
        guard hasTrack else { return }
        applyLoop(LoopEditing.settingIn(at: playhead, in: loop, totalFrames: totalFrames))
    }

    public func setLoopOut() {
        guard hasTrack else { return }
        applyLoop(LoopEditing.settingOut(at: playhead, in: loop, totalFrames: totalFrames))
    }

    public func loopFromSelection() {
        guard hasTrack else { return }
        applyLoop(LoopEditing.fromSelection(selection.range, in: loop, totalFrames: totalFrames))
    }

    public func toggleLoop() {
        guard hasTrack else { return }
        var next = loop
        next.isEnabled.toggle()
        applyLoop(next)
    }

    /// `F`. Jumps to the loop's in point without changing whether it is enabled,
    /// so it doubles as "play this phrase again from the top".
    public func restartLoop() {
        guard hasTrack, loop.range.count > 0 else { return }
        seek(to: loop.range.start)
    }

    public func clearLoop() {
        guard hasTrack else { return }
        applyLoop(LoopRegion())
    }

    /// The app's one and only `PlaybackCommand.setLoop` path. Internal rather
    /// than private so a dragged loop edge (`ViewerModel+EdgeDrag`) goes through
    /// it too — the alternative would be a second way to reach the render
    /// thread, which spec §5 does not have.
    func applyLoop(_ next: LoopRegion) {
        guard next != loop else { return }
        loop = next
        // The geometry the wrap detector measures against has just changed, so
        // its remembered position is from a different region: a loop dragged
        // shorter under a running ramp would otherwise report a phantom wrap.
        wrapTracker.reset()
        // Takes effect on the next pass, not this one: the engine wraps at the
        // boundary it is fed, and never resets the stretcher there (spec §5.1).
        session?.push(.setLoop(loop.range, loop.isEnabled))
        markSessionEdited()
    }
}
