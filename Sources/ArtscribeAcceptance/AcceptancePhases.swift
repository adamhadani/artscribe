import AppKit
import ArtscribeKit
import ArtscribeUI
import Foundation
import Playback

/// The run, in phases, with each group gated on the plan.
///
/// Split out of `AcceptanceRun.swift` for file length alone; the order below is
/// the order it has always run in, and the comments explaining why a check sits
/// where it does travelled with it. What is new is that every stretch is now
/// wrapped in `log.running(_:)`, which both gates the group and times it.
///
/// Groups are **not** contiguous by construction — `menu`, `edge`, `theme` and
/// `shortcuts` each have two stretches, separated by checks that must sit
/// between them. `Logger` accumulates a group's time and count across its
/// openings rather than forcing the run into an order that would break it.
extension AcceptanceRun {

    /// What the command line pointed the run at. One value rather than four
    /// parameters threaded through six phase functions.
    struct Inputs {
        let audio: URL
        let badFile: URL?
        let outputDirectory: String
    }

    /// Everything that has to be true before any group can run, and the load
    /// every group depends on. Never skippable: there is no acceptance check of
    /// any kind to make without a track on screen.
    @MainActor
    static func prelude(model: ViewerModel, run: Inputs, log: inout Logger) async {
        // Asserted, not assumed: the whole point is that no run can make a noise
        // by accident, so the run says whether it can.
        log.check(
            "this run cannot reach the speakers", OutputAudibility.shared.isSilenced,
            unless: ProcessInfo.processInfo.environment[audibleEnvironmentKey] == "1"
                ? "\(audibleEnvironmentKey)=1 was set, so this run is deliberately audible" : nil)
        await settle(seconds: 1.0)
        // macOS restores a window's saved frame, so pin a known size: otherwise
        // the resize check below shrinks the window a little on every run.
        await normaliseWindow()
        log.check("regular activation policy (menu bar)", NSApp.activationPolicy() == .regular)
        log.note("app active / key window", "\(NSApp.isActive) / \(NSApp.keyWindow != nil)")
        log.check(
            "window can take keyboard focus",
            NSApp.windows.first.map { $0.canBecomeKey } ?? false)
        log.note(
            "first responder",
            "\(NSApp.windows.first?.firstResponder.map(String.init(describing:)) ?? "none")")

        await checkLoad(model: model, url: run.audio, log: &log)
        checkStructure(model: model, log: &log)
        snapshot(to: "\(run.outputDirectory)/01-loaded.png")
    }

    /// `pointer`, `cursor`, `edge`, `zoom` — everything driven by the mouse and
    /// everything that changes what is on screen.
    @MainActor
    static func runViewGroups(
        model: ViewerModel, theme: ThemeController, run: Inputs, log: inout Logger
    ) async {
        // Task 17, and deliberately early. The same gestures Task 16 could only
        // reach through the model, this time as real pointer events into
        // SwiftUI's own machinery, plus the cursors that advertise them. Both
        // need a key window and a pointer this process can aim; a run lasts
        // minutes on a machine somebody else may be using, and by the time the
        // playback checks are done neither is reliably still true.
        if log.running(.pointer) {
            await checkPointerGestures(model: model, log: &log)
        }
        if log.running(.cursor) {
            await checkPointerAffordances(model: model, log: &log)
        }
        // Task 23, deliberately immediately after them and for the same reason:
        // it needs a key window and a pointer this process can aim. It leaves
        // the loop and the selection cleared, so nothing downstream inherits a
        // region it did not ask for.
        if log.running(.edge) {
            await checkEdgeDrag(
                model: model, theme: theme, log: &log, outputDirectory: run.outputDirectory)
        }

        if log.running(.zoom) {
            checkZoomAnchor(model: model, log: &log)
            await settle(seconds: 0.2)
            snapshot(to: "\(run.outputDirectory)/02-zoomed.png")

            await checkDeepZoom(model: model, log: &log, outputDirectory: run.outputDirectory)

            checkPanClamping(model: model, log: &log)
            await checkTrackpad(model: model, log: &log)
            await checkScrollZoom(model: model, log: &log)
            await checkDragZoom(model: model, log: &log)
            await checkZoomDirection(model: model, log: &log)
        }
    }

    /// `theme`, `menu`, `shortcuts`, `transport`, `navigation` — the window's
    /// chrome and the two ways to reach an action that is not a gesture.
    @MainActor
    static func runChromeGroups(
        model: ViewerModel, theme: ThemeController, run: Inputs, log: inout Logger
    ) async {
        if log.running(.theme) {
            await checkSpeedEmphasis(model: model, log: &log, outputDirectory: run.outputDirectory)
        }
        if log.running(.menu) {
            await checkFileAndViewMenus(model: model, log: &log)
        }
        // Task 15. The presentation and strobe checks read the menus; the
        // transport bar checks click real buttons and then press Space.
        if log.running(.shortcuts) {
            await checkShortcutPresentation(log: &log)
            await checkMenuBarStrobe(model: model, log: &log)
            checkSingleFire(model: model, log: &log)
            await checkDisabledItemsClaimNothing(model: model, log: &log)
        }
        if log.running(.transport) {
            await checkTransportBar(
                model: model, theme: theme, log: &log, outputDirectory: run.outputDirectory)
        }
        if log.running(.navigation) {
            await checkNudge(model: model, log: &log)
            await checkSettings(model: model, theme: theme, log: &log)
        }
        if log.running(.theme) {
            await checkTheme(
                model: model, theme: theme, log: &log, outputDirectory: run.outputDirectory)
        }
    }

    /// `selection`, `menu`'s two region menus, and `loop`.
    @MainActor
    static func runRegionGroups(
        model: ViewerModel, log: inout Logger, run: Inputs
    ) async {
        if log.running(.selection) {
            await checkSelection(model: model, log: &log)
            await settle(seconds: 0.2)
            snapshot(to: "\(run.outputDirectory)/03-selection.png")

            await checkZoomToSelection(model: model, log: &log)
            await settle(seconds: 0.2)
            snapshot(to: "\(run.outputDirectory)/04-zoom-to-selection.png")

            // Task 18: the selection moves and extends. Deliberately *after*
            // `checkZoomToSelection`, which reads the selection this leaves
            // cleared — measured, as a ⌘9 check that framed an empty range.
            await checkSelectionMovement(model: model, log: &log)
        }
        if log.running(.menu) {
            await checkEditMenu(model: model, log: &log)
            await checkLoopMenu(model: model, log: &log)
        }
        if log.running(.loop) {
            await checkLoopMovement(model: model, log: &log)
        }
    }

    /// `playback` and `start` — the two slow groups, which wait on real audio —
    /// plus the edge drag that needs a running transport, and the resize.
    @MainActor
    static func runPlaybackGroups(
        model: ViewerModel, log: inout Logger, run: Inputs
    ) async {
        if log.running(.playback) {
            await checkPlayback(model: model, log: &log, outputDirectory: run.outputDirectory)
            await settle(seconds: 0.2)
            snapshot(to: "\(run.outputDirectory)/07-playback.png")
        }

        // Task 22. Both open the audio graph for themselves, and the
        // double-click one also needs the window to still be key, which it
        // re-asserts.
        if log.running(.start) {
            await checkStartPrecedence(model: model, log: &log)
            await checkDoubleClickPlays(model: model, log: &log)
        }
        // Task 23's seamless half: an edge moved with the transport running.
        // Here rather than with the other edge checks because it needs an audio
        // graph, which it checks for itself before driving.
        if log.running(.edge) {
            await checkEdgeDragWhilePlaying(model: model, log: &log)
        }

        if log.running(.window) {
            await checkResize(model: model, log: &log)
            await settle(seconds: 0.3)
            snapshot(to: "\(run.outputDirectory)/05-resized.png")
        }
    }

    /// `session`, the `window` group's error banner, `catalog`, and the one
    /// shortcut check that has to be last.
    @MainActor
    static func runSessionGroups(
        model: ViewerModel, theme: ThemeController, context: MenuContext, run: Inputs,
        log: inout Logger
    ) async {
        // Task 19. Deliberately on a *copy* of the track in a scratch folder,
        // never beside the real media the run was pointed at, and deliberately
        // before `checkBadFile`, which leaves a failed load on screen.
        if log.running(.session) {
            await checkSession(model: model, log: &log, source: run.audio)
            await settle(seconds: 0.2)
            snapshot(to: "\(run.outputDirectory)/08-session.png")
        }

        if log.running(.window) {
            if let badFile = run.badFile {
                await checkBadFile(model: model, url: badFile, log: &log)
            }
            await settle(seconds: 0.3)
            snapshot(to: "\(run.outputDirectory)/06-error-banner.png")
        }

        // Tasks 20 and 25: the menu bar against the catalog, and the shortcut
        // window. Deliberately after every pointer check — it opens a second
        // window and takes the keyboard focus with it, and the lane coordinates
        // those checks aim at are measured against the document window.
        if log.running(.catalog) {
            await checkCatalogAndShortcutWindow(
                model: model, theme: theme, context: context, log: &log,
                outputDirectory: run.outputDirectory)
        }

        // Task 21's Practice hub. Deliberately after `catalog`, for the same
        // reason `catalog` is late: it opens a second window and takes the
        // keyboard focus with it. It plays real audio, so it also has to come
        // after everything that measures a stationary playhead.
        if log.running(.practice) {
            await checkPracticeHub(
                model: model, theme: theme, context: context, log: &log,
                outputDirectory: run.outputDirectory)
        }

        // Deliberately last. It puts a text field into the window's responder
        // chain, and a field left there swallows every later keystroke — which
        // is exactly what happened the first time it ran earlier in the run.
        if log.running(.shortcuts) {
            await checkTypingInAField(model: model, log: &log)
        }
    }
}
