import AppKit
import ArtscribeKit
import ArtscribeUI
import Foundation

/// The Task 11 half of the acceptance run: transport, speed, loop, page-flip
/// auto-scroll, the Playback menu, and the render-thread counters.
///
/// Every keystroke goes through `NSApp.sendEvent`, so the menu bar's key
/// equivalents, the window's first responder and `onKeyPress` are all exercised
/// for real. Where a claim can only be made by ear it is measured instead, and
/// the measurement is reported as a measurement.
extension AcceptanceRun {

    @MainActor
    static func checkPlayback(
        model: ViewerModel, log: inout Logger, outputDirectory: String
    ) async {
        model.fitWholeFile()
        model.clearSelection()
        model.seek(to: 0)

        log.check("an audio output was opened for the loaded track", model.canPlay)
        guard model.canPlay else {
            log.note("playback", "no audio output; the remaining checks cannot run")
            return
        }

        await checkTransport(model: model, log: &log)
        checkVolume(model: model, log: &log)
        await checkSpeed(model: model, log: &log)
        await checkLoop(model: model, log: &log, outputDirectory: outputDirectory)
        await checkAutoScroll(model: model, log: &log)
        await checkPlaybackMenu(model: model, log: &log)
        checkCounters(model: model, log: &log)
    }

    // MARK: - Transport

    @MainActor
    private static func checkTransport(model: ViewerModel, log: inout Logger) async {
        press(.space)
        // The trap: `isPlaying` on the engine is not observable until the render
        // thread drains the ring, so the *button* must be true immediately.
        log.check("Space is handled and the transport latches immediately", model.isPlaying)

        await settle(seconds: 0.6)
        let moved = model.playhead
        log.check("the playhead advances during playback (\(moved) frames)", moved > 0)
        await settle(seconds: 0.6)
        let later = model.playhead
        log.check("the playhead keeps advancing (\(moved) → \(later))", later > moved)

        // Real time against source time: at 1.0x they must agree to well within
        // the poll interval. This is the objective form of "the playhead stays
        // synchronised with what you hear".
        let elapsed = Double(later - moved) / model.sampleRate
        log.note("playhead advance over ~0.6 s of wall clock", String(format: "%.3f s", elapsed))
        log.check("the playhead tracks real time at 1.0x", abs(elapsed - 0.6) < 0.15)

        press(.space)
        log.check("Space pauses", !model.isPlaying)
        await settle(seconds: 0.3)
        let paused = model.playhead
        await settle(seconds: 0.4)
        log.check("the playhead stops when paused", model.playhead == paused)

        press(.enter)
        log.check("Return plays from the start", model.isPlaying)
        await settle(seconds: 0.2)
        log.check("Return moved the position back to zero", model.playhead < paused)
        press(.space)
        await settle(seconds: 0.1)
    }

    // MARK: - Volume

    /// Every claim here is checked against `AudioOutput.volume` — the value the
    /// mixer actually holds — as well as against the model, because "the readout
    /// says 40%" is not the same claim as "the graph is at 0.4".
    @MainActor
    private static func checkVolume(model: ViewerModel, log: inout Logger) {
        // `-1` is deliberately unreachable, so a missing graph fails loudly
        // rather than passing a comparison against 0.
        func mixer() -> Double { model.outputVolume ?? -1 }

        log.check("a fresh session opens at half scale, not full", model.volume.level == 0.5)
        log.check(
            "the mixer is actually at half scale (\(rounded(mixer())))",
            abs(mixer() - 0.5) < 0.001)

        let playheadBefore = model.playhead
        press(.up)
        log.check(
            "↑ steps up exactly one 5% notch (\(model.volume.level))",
            model.volume.level == 0.55)
        press(.down)
        log.check("↓ steps back down exactly one notch", model.volume.level == 0.5)
        press(.shiftUp)
        log.check(
            "⇧↑ steps up exactly one 1% notch (\(model.volume.level))",
            model.volume.level == 0.51)
        press(.shiftDown)
        log.check("⇧↓ steps back down one 1% notch", model.volume.level == 0.5)
        log.check(
            "a fine step really is finer than a coarse one",
            VolumeState.fineStep < VolumeState.coarseStep)

        // The arrows must not have moved anything else — this is the
        // double-binding check the coordinator asked for.
        log.check("↑↓ did not touch the speed", model.speed.ratio == 1.0)
        log.check("↑↓ did not move the playhead", model.playhead == playheadBefore)
        log.check("↑↓ did not touch the loop", model.loop.range.isEmpty)

        model.setVolumeLevel(0.4)
        log.check(
            "the slider drives the mixer (\(rounded(mixer())))",
            abs(mixer() - 0.4) < 0.001)

        press(.m)
        log.check("M mutes", model.volume.isMuted)
        log.check(
            "muting takes the mixer to silence (\(rounded(mixer())))",
            mixer() == 0)
        log.check("muting does not lose the level the slider shows", model.volume.level == 0.4)
        press(.m)
        log.check("M unmutes", !model.volume.isMuted)
        log.check(
            "unmuting restores the prior level, not full scale "
                + "(\(rounded(mixer())))",
            abs(mixer() - 0.4) < 0.001)

        press(.m)
        press(.up)
        log.check("↑ while muted unmutes and makes sound", !model.volume.isMuted)
        log.check(
            "and the mixer follows (\(rounded(mixer())))",
            abs(mixer() - 0.45) < 0.001)

        model.setVolumeLevel(1.0)
        for _ in 0..<3 { press(.up) }
        log.check("volume clamps at full scale", model.volume.level == 1.0)
        model.setVolumeLevel(0.0)
        for _ in 0..<3 { press(.down) }
        log.check("volume clamps at silence", model.volume.level == 0.0)
        log.check(
            "and silence really is silence at the mixer", mixer() == 0)

        model.setVolumeLevel(VolumeState.defaultLevel)
    }

    // MARK: - Speed

    /// Also the double-fire check. If a plain letter were both a menu key
    /// equivalent and a window binding, one press would step twice — so the exact
    /// value after a single press is the evidence, not just "it changed".
    @MainActor
    private static func checkSpeed(model: ViewerModel, log: inout Logger) async {
        model.setSpeedPreset(1.0)
        press(.w)
        log.check(
            "W steps up exactly one 5% notch (\(model.speed.ratio))", model.speed.ratio == 1.05)
        press(.q)
        log.check("Q steps back down exactly one notch", model.speed.ratio == 1.0)
        press(.shiftW)
        log.check(
            "⇧W steps up exactly one 1% notch (\(model.speed.ratio))", model.speed.ratio == 1.01)
        press(.shiftQ)
        log.check("⇧Q steps back down one 1% notch", model.speed.ratio == 1.0)

        press(.three)
        log.check("3 selects the 50% preset", model.speed.ratio == 0.5)
        log.check("half speed is a time ratio of two, not a half", model.speed.timeRatio == 2.0)
        press(.two)
        log.check("2 selects the 75% preset", model.speed.ratio == 0.75)
        press(.four)
        log.check("4 selects the 33% preset", model.speed.ratio == 0.33)
        press(.one)
        log.check("1 returns to 100%", model.speed.ratio == 1.0)

        let engineBefore = model.speed.engine
        press(.optionE)
        log.check(
            "⌥E toggles the stretch engine (\(engineBefore) → \(model.speed.engine))",
            model.speed.engine != engineBefore)
        press(.optionE)
        log.check("⌥E toggles back", model.speed.engine == engineBefore)

        // Changing speed while playing must not lose position. Measured across
        // the change, at the position the listener is at.
        model.seek(to: FrameIndex(model.sampleRate * 5))
        press(.space)
        await settle(seconds: 0.5)
        let before = model.playhead
        press(.three)
        await settle(seconds: 0.05)
        let after = model.playhead
        log.check(
            "changing speed mid-playback does not jump position "
                + "(\(before) → \(after) frames)",
            abs(after - before) < FrameIndex(model.sampleRate * 0.2))

        // At half speed the playhead must cover half as much source per second.
        await settle(seconds: 0.1)
        let start = model.playhead
        await settle(seconds: 0.8)
        let covered = Double(model.playhead - start) / model.sampleRate
        log.note("source covered in ~0.8 s at 50% speed", String(format: "%.3f s", covered))
        log.check("50% speed advances the playhead at half rate", covered > 0.25 && covered < 0.55)

        press(.space)
        press(.one)
        await settle(seconds: 0.1)
    }

    // MARK: - Loop

    @MainActor
    private static func checkLoop(
        model: ViewerModel, log: inout Logger, outputDirectory: String
    ) async {
        model.fitWholeFile()
        model.clearSelection()

        // The acceptance script, exactly: drag-select, then G, then D.
        model.dragChanged(startPixel: 300, currentPixel: 300, extending: false)
        model.dragChanged(startPixel: 300, currentPixel: 340, extending: false)
        model.dragEnded(
            startPixel: 300, endPixel: 340, now: ProcessInfo.processInfo.systemUptime)
        let selected = model.selection.range
        press(.g)
        log.check("G turns the selection into the loop region", model.loop.range == selected)
        log.check("G alone does not start looping", !model.loop.isEnabled)
        press(.d)
        log.check("D enables looping", model.loop.isActive)
        press(.d)
        model.clearLoop()

        // The brief's listening check, measured: a four-second loop at 50%
        // speed. Four seconds is deliberate — long enough to be musical, short
        // enough that several passes fit inside a reasonable observation window.
        let inPoint = FrameIndex(model.sampleRate * 30)
        let outPoint = FrameIndex(model.sampleRate * 34)
        model.seek(to: inPoint)
        press(.a)
        log.check("A sets the loop in point at the playhead", model.loop.range.start == inPoint)
        model.seek(to: outPoint)
        press(.s)
        log.check("S sets the loop out point at the playhead", model.loop.range.end == outPoint)
        press(.d)
        press(.three)
        model.seek(to: inPoint)
        press(.space)

        // Position is sampled throughout. The objective form of "it repeats
        // seamlessly" is that the playhead never leaves the region, comes back
        // to the start repeatedly, and no render stall is counted while it does
        // — a click at the seam would be a stall or a discontinuity, and both
        // are visible here.
        let stallsBefore = model.degradation.stalls
        // A picture of the loop actually running, zoomed in far enough that the
        // region, its posts and the playhead are all legible.
        await settle(seconds: 0.6)
        for _ in 0..<9 { model.zoomIn() }
        model.centre(on: inPoint + (outPoint - inPoint) / 2)
        await settle(seconds: 0.3)
        snapshot(to: "\(outputDirectory)/08-looping.png")
        var outside = 0
        var wraps = 0
        var previous = model.playhead
        let deadline = Date().addingTimeInterval(18)
        while Date() < deadline {
            await settle(seconds: 0.02)
            let now = model.playhead
            // A block of slack either side: the audible position is exact, but
            // the poll can land anywhere inside one render quantum.
            if now < inPoint - 4096 || now > outPoint + 4096 { outside += 1 }
            if now < previous - 4096 { wraps += 1 }
            previous = now
        }
        log.check(
            "the playhead never leaves the loop region (\(outside) samples outside)", outside == 0)
        log.check(
            "a 4 s loop at 50% speed repeats (\(wraps) wraps observed over 18 s)", wraps >= 2)
        log.check(
            "no render stall at any loop seam",
            model.degradation.stalls == stallsBefore)
        log.check("the transport is still playing after looping", model.isPlaying)

        press(.space)
        press(.one)
        await settle(seconds: 0.1)

        model.seek(to: FrameIndex(model.sampleRate * 32))
        press(.f)
        log.check("F restarts the loop from its in point", model.playhead == inPoint)
        press(.d)
        log.check("D toggles looping off again", !model.loop.isActive)
        model.clearLoop()
    }

    // MARK: - Auto-scroll

    /// Page-flip, not continuous scrolling: the viewport must be *stationary*
    /// across most polls and move in whole pages when it moves at all.
    @MainActor
    private static func checkAutoScroll(model: ViewerModel, log: inout Logger) async {
        model.clearLoop()
        model.clearSelection()
        model.fitWholeFile()
        model.seek(to: 0)
        // Zoomed until a page is a few seconds wide, so several flips fit into
        // the observation window below.
        for _ in 0..<14 { press(.r) }
        let visible = model.viewport.visibleFrames
        log.note(
            "auto-scroll page width",
            String(format: "%.2f s", Double(visible) / model.sampleRate))
        model.seek(to: model.viewport.startFrame + visible / 8)

        press(.space)
        var starts: [FrameIndex] = []
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            await settle(seconds: 0.02)
            starts.append(model.viewport.startFrame)
        }
        press(.space)

        let jumps = zip(starts, starts.dropFirst()).filter { $0 != $1 }.count
        let distinct = Set(starts).count
        log.note(
            "viewport over ~6 s of playback",
            "\(distinct) distinct positions in \(starts.count) polls, \(jumps) moves")
        log.check(
            "the view is stationary between flips, not scrolling continuously",
            jumps <= starts.count / 8)
        log.check("the view did follow the playhead", distinct > 1)
        if distinct > 1, let first = starts.first, let last = starts.last {
            let perFlip = (last - first) / FrameIndex(distinct - 1)
            log.check(
                "each flip moves about a page (\(perFlip) frames vs \(visible) visible)",
                perFlip > visible / 2)
        } else {
            log.check("each flip moves about a page", false)
        }

        // Now with a loop that fits: the view must not move at all.
        model.seek(to: model.viewport.startFrame)
        let loopStart = model.viewport.startFrame + visible / 8
        model.seek(to: loopStart)
        press(.a)
        model.seek(to: loopStart + visible / 2)
        press(.s)
        press(.d)
        model.seek(to: loopStart)
        let held = model.viewport.startFrame
        press(.space)
        var moved = false
        let loopDeadline = Date().addingTimeInterval(4)
        while Date() < loopDeadline {
            await settle(seconds: 0.02)
            if model.viewport.startFrame != held { moved = true }
        }
        press(.space)
        log.check("an active loop that fits on screen suppresses auto-scroll entirely", !moved)
        model.clearLoop()
        await settle(seconds: 0.1)
    }
}
