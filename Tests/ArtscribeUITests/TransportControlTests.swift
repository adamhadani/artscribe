import AppKit
import ArtscribeKit
import AudioDecode
import Foundation
import Testing
import Waveform

@testable import ArtscribeUI

/// The transport bar's pure half: what each button is called, which symbol it
/// draws, when it is enabled, when it reads as *on*, and — the item that
/// matters most — that pressing it does exactly what the key does.
///
/// The view itself is not snapshot-tested (project convention), so everything
/// worth asserting lives in `TransportControl` and in `ViewerModel.perform(_:)`,
/// which is the single dispatch every button goes through.
@MainActor
@Suite("Transport bar controls")
struct TransportControlTests {

    private static let sampleRate: Double = 44100
    private static let totalFrames: FrameIndex = 441_000  // 10 s

    private func makeModel(frames: FrameIndex = Self.totalFrames) -> ViewerModel {
        let storage = AudioStorage(channels: 1, capacityFrames: Int(frames))
        let audio = DecodedAudio(
            channels: 1, sampleRate: Self.sampleRate, frameCount: frames, storage: storage)
        let model = ViewerModel()
        model.loadForTesting(audio: audio, pyramid: PeakPyramid.build(audio), widthPixels: 1000)
        return model
    }

    // MARK: - Presentation

    @Test("every control names a real SF Symbol, in both transport states")
    func symbolsResolve() {
        for control in TransportControl.allCases {
            for playing in [false, true] {
                var state = TransportState()
                state.isPlaying = playing
                let name = control.symbol(in: state)
                #expect(
                    NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                    "\(control) draws \(name)")
            }
        }
    }

    /// The bar teaches the keyboard, so a rebinding that misses the bar leaves
    /// it teaching a key that no longer does anything — the drift this project
    /// has been bitten by twice. Task 18 moved play-from-start off `Return`;
    /// Task 28 moved it again onto `Space` and Task 29 put it back on `⇧Space`.
    ///
    /// `TransportControl.faces` spells its shortcuts as literals, so this
    /// compares them against `ActionCatalog` rather than against a second
    /// literal — a literal-versus-literal assertion would have passed unchanged
    /// through both rebinds while the bar taught the wrong key. This is the
    /// cheap half of keeping the two in step; the expensive half is the
    /// acceptance run, which reads the menu's *real* key equivalent out of
    /// AppKit and then presses it.
    @Test("the transport buttons teach the bindings the catalog carries")
    func transportButtonsTeachTheCatalogBindings() {
        #expect(
            TransportControl.playFromStart.shortcut
                == ActionCatalog.chord(.transportReturnToStart)?.display)
        #expect(
            TransportControl.playPause.shortcut
                == ActionCatalog.chord(.transportPlayPause)?.display)
        // And the pairing itself, named once, so a catalog edit that moved both
        // sides together still has to face what the user asked for.
        #expect(TransportControl.playFromStart.shortcut == "⇧Space")
        #expect(TransportControl.playPause.shortcut == "Space")
    }

    @Test("every control teaches its key in the tooltip")
    func tooltipsCarryTheShortcut() {
        for control in TransportControl.allCases {
            var state = TransportState()
            state.isPlaying = control == .playPause
            let tooltip = control.tooltip(in: state)
            #expect(!control.shortcut.isEmpty, "\(control) has no shortcut to teach")
            #expect(tooltip.contains(control.shortcut), "\(control): \(tooltip)")
            #expect(tooltip.contains(control.title(in: state)), "\(control): \(tooltip)")
        }
    }

    @Test("the play button says what pressing it will do")
    func playPauseFollowsTheTransport() {
        var stopped = TransportState()
        stopped.isPlaying = false
        var playing = stopped
        playing.isPlaying = true
        #expect(TransportControl.playPause.symbol(in: stopped) == "play.fill")
        #expect(TransportControl.playPause.symbol(in: playing) == "pause.fill")
        #expect(TransportControl.playPause.title(in: stopped) == "Play")
        #expect(TransportControl.playPause.title(in: playing) == "Pause")
    }

    // MARK: - Enablement

    @Test("nothing on the bar is live with no track loaded")
    func everythingIsDisabledWithoutATrack() {
        let state = TransportState()
        #expect(!state.hasTrack)
        for control in TransportControl.allCases {
            #expect(!control.isEnabled(in: state), "\(control) is live with no track")
        }
    }

    @Test("the loop button follows the same rule as the Loop menu item")
    func loopEnablement() {
        var state = TransportState()
        state.hasTrack = true
        // No region and switched off: nothing to toggle.
        state.loopIsEmpty = true
        state.loopIsEnabled = false
        #expect(!TransportControl.loop.isEnabled(in: state))
        // Switched on with no region is a state you must be able to leave.
        state.loopIsEnabled = true
        #expect(TransportControl.loop.isEnabled(in: state))
        state.loopIsEmpty = false
        state.loopIsEnabled = false
        #expect(TransportControl.loop.isEnabled(in: state))
    }

    @Test("the loop button reads on/off, and only the loop button does")
    func onlyLoopCarriesAnOnState() {
        var state = TransportState()
        state.hasTrack = true
        state.loopIsEmpty = false
        state.loopIsEnabled = true
        state.isPlaying = true
        for control in TransportControl.allCases where control != .loop {
            #expect(!control.isOn(in: state), "\(control) claims an on-state")
        }
        #expect(TransportControl.loop.isOn(in: state))
        state.loopIsEnabled = false
        #expect(!TransportControl.loop.isOn(in: state))
    }

    @Test("the bar's speed readout carries the status bar's emphasis rule")
    func speedEmphasisMatchesTheStatusBar() {
        var state = TransportState()
        state.speedRatio = 1.0
        #expect(!state.speedIsEmphasised)
        #expect(state.speedLabel == "100%")
        state.speedRatio = 0.5
        #expect(state.speedIsEmphasised)
        #expect(state.speedLabel == "50%")
        #expect(state.speedIsEmphasised == SpeedStepping.isAltered(state.speedRatio))
    }

    @Test("the model's own state is what the bar draws from")
    func stateIsReadOffTheModel() {
        let model = makeModel()
        #expect(model.transportState.hasTrack)
        #expect(model.transportState.loopIsEmpty)
        #expect(!model.transportState.loopIsEnabled)
        model.selectAll()
        model.loopFromSelection()
        #expect(!model.transportState.loopIsEmpty)
        model.toggleLoop()
        #expect(model.transportState.loopIsEnabled == model.loop.isEnabled)
        model.setSpeedPreset(0.5)
        #expect(model.transportState.speedRatio == 0.5)
        #expect(ViewerModel().transportState == TransportState())
    }

    // MARK: - Dispatch
    //
    // The load-bearing item: a button must be a second front-end to the action
    // the key already invokes, not a reimplementation of it.

    @Test("the nudge buttons move exactly as far as their keys do")
    func nudgeButtonsMatchTheKeys() {
        let byKey = makeModel()
        let byButton = makeModel()
        for model in [byKey, byButton] { model.seek(to: 220_500) }

        byKey.nudge(.normal, direction: .backward)
        byButton.perform(.nudgeBackward)
        #expect(byButton.playhead == byKey.playhead)

        byKey.nudge(.normal, direction: .forward)
        byButton.perform(.nudgeForward)
        #expect(byButton.playhead == byKey.playhead)

        byKey.nudge(.coarse, direction: .backward)
        byButton.perform(.rewind)
        #expect(byButton.playhead == byKey.playhead)

        byKey.nudge(.coarse, direction: .forward)
        byButton.perform(.skip)
        #expect(byButton.playhead == byKey.playhead)
        // Not vacuous: the two coarse steps must actually have gone somewhere.
        #expect(byKey.playhead != 220_500)
    }

    @Test("the speed buttons step exactly as Q and W do")
    func speedButtonsMatchTheKeys() {
        let model = makeModel()
        model.perform(.slower)
        #expect(model.speed.ratio == 0.95)
        model.perform(.faster)
        #expect(model.speed.ratio == 1.0)
    }

    @Test("the zoom buttons zoom exactly as E and R do")
    func zoomButtonsMatchTheKeys() {
        let byKey = makeModel()
        let byButton = makeModel()
        byKey.zoomIn()
        byButton.perform(.zoomIn)
        #expect(byButton.framesPerPixel == byKey.framesPerPixel)
        #expect(byButton.framesPerPixel < byButton.viewport.maxFramesPerPixel)
        byKey.zoomOut()
        byButton.perform(.zoomOut)
        #expect(byButton.framesPerPixel == byKey.framesPerPixel)
    }

    @Test("the loop button toggles the loop and nothing else")
    func loopButtonTogglesTheLoop() {
        let model = makeModel()
        model.selectAll()
        model.loopFromSelection()
        let range = model.loop.range
        let enabled = model.loop.isEnabled
        model.perform(.loop)
        #expect(model.loop.isEnabled == !enabled)
        #expect(model.loop.range == range)
    }

    @Test("play-from-selection-start goes where Shift-Space goes")
    func playFromStartButtonSeeksToTheSelection() {
        let model = makeModel()
        model.dragChanged(startPixel: 200, currentPixel: 520, extending: false)
        model.dragEnded(startPixel: 200, endPixel: 520, now: 0)
        let start = model.selection.range.start
        #expect(start > 0)
        model.seek(to: 0)
        model.perform(.playFromStart)
        #expect(model.playhead == start)
    }

    @Test("the play button asks the transport to change, and reports when it cannot")
    func playPauseButtonDrivesTheTransport() {
        let model = makeModel()
        #expect(!model.isPlaying)
        model.perform(.playPause)
        // No audio session exists in a unit test, so play cannot succeed — and
        // must say so rather than pretend, exactly as the Space key does.
        #expect(!model.isPlaying)
        #expect(model.playbackNotice != nil)
    }

    @Test("every control is a no-op with no track loaded")
    func nothingFiresWithoutATrack() {
        for control in TransportControl.allCases {
            let model = ViewerModel()
            model.perform(control)
            #expect(model.playhead == 0, "\(control) moved the playhead with no track")
            #expect(model.loop == LoopRegion(), "\(control) touched the loop with no track")
        }
    }

    @Test("the bar's groups cover every control exactly once, in order")
    func groupsCoverEveryControl() {
        let flattened = TransportControl.groups.flatMap { $0 }
        #expect(flattened == TransportControl.allCases)
        #expect(Set(flattened).count == flattened.count)
        // The layout the plan asks for: transport cluster, play-from-start,
        // loop, speed, zoom.
        #expect(TransportControl.groups.count == 5)
        #expect(
            TransportControl.groups[0] == [
                .rewind, .nudgeBackward, .playPause, .nudgeForward, .skip
            ])
        #expect(TransportControl.groups[3] == [.slower, .faster])
    }
}
