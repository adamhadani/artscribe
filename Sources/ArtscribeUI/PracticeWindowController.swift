import AppKit
import ArtscribeKit
import Foundation
import SwiftUI

/// The Practice window's identity, and the one way to open it.
///
/// A near-copy of `ShortcutWindowController`, deliberately: both are application
/// state rather than track state — the window outlives every loaded track and is
/// closable on its own — and both exist because `openWindow(id:)` is an
/// `EnvironmentValues` member reachable only from inside a `View` body, while
/// `ActionInvoker`'s table is not a view on purpose. The scene hands its
/// `openWindow` over once, on appear, and the action calls it.
///
/// This one holds no view state of its own. The Practice window has exactly one
/// thing to remember between openings — the ramp the user set up — and that is
/// *applied* state living on `ViewerModel`, with `PracticeSettings` as its
/// backing tape, the same arrangement `NudgeSettings` has.
@MainActor
public final class PracticeWindowController {
    /// The scene id, and the `NSWindow` frame-autosave name. One constant so the
    /// scene, the opener and the harness cannot disagree about which window is
    /// meant.
    public static let windowID = "practice"

    /// Opening, raising, focusing and closing — shared with the shortcut window
    /// rather than copied from it. See `AuxiliaryWindow`: this controller had
    /// both of the defects that window was fixed for, because it was written as
    /// a near-copy before either fix existed.
    public let windowState = AuxiliaryWindow()

    /// Installed by the scene. Plumbing written once at launch.
    public var present: (@MainActor () -> Void)? {
        get { windowState.present }
        set { windowState.present = newValue }
    }

    public init() {}

    /// `⌘P`, and **View ▸ Practice**. Opens, raises, and gives it the keyboard.
    public func show() { windowState.show() }

    /// `⌘P` again puts it away, matching `⌘/`. The earlier claim that a toggle
    /// would be "a third behaviour for no gain" was wrong in the same way it was
    /// wrong for the shortcut window: pressed while the window is already in
    /// front, a non-toggling key does *nothing at all*, which reads as broken.
    public func toggle() { windowState.toggle() }

    /// Told which `NSWindow` the ramp ended up in, by the view inside it.
    public func adopt(window: NSWindow?) { windowState.window = window }
}

extension View {
    /// Hands the scene's `openWindow` to the controller — the whole of the
    /// plumbing behind `⌘P`, and the mirror of `openShortcutWindow`.
    ///
    /// Applied to **every** scene that can be showing when `⌘P` is pressed, so
    /// the key works whichever of them is key.
    public func openPracticeWindow(_ practice: PracticeWindowController) -> some View {
        modifier(PracticeWindowOpener(practice: practice))
    }
}

private struct PracticeWindowOpener: ViewModifier {
    let practice: PracticeWindowController
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            practice.present = { openWindow(id: PracticeWindowController.windowID) }
        }
    }
}

/// Where the ramp the user set up is kept between launches.
///
/// A plain store, not an `@Observable`: the applied schedule lives on
/// `ViewerModel.ramp`, which is what the window and the ramp itself read, so
/// there is one source of truth and this is only its backing tape. The same
/// split as `NudgeSettings`, and for the same second reason — it keeps
/// `UserDefaults` out of `ViewerModel()`, which unit tests build by the dozen.
///
/// **The schedule is remembered and the run is not.** How slow you have to start
/// a passage and how many passes it takes you is a fact about the passage and
/// about you; which repetition you were on when you quit is a fact about
/// Tuesday. Restoring a half-finished ramp on launch would leave the transport
/// at 72% for reasons nothing on screen could explain.
@MainActor
public final class PracticeSettings {

    private static let key = "practice.ramp"

    private let defaults: UserDefaults

    /// - Parameter defaults: injectable so tests and the acceptance harness get
    ///   their own suite instead of writing into the user's real preferences.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored schedule, or the shipped default.
    ///
    /// Anything that will not decode is discarded rather than repaired in place:
    /// `RampSchedule`'s own decoder already falls back field by field, so a
    /// failure here means the stored blob is not a schedule at all — written by
    /// an older build, or by `defaults write` — and the shipped default is a
    /// better answer than a guess.
    public func load() -> RampSchedule {
        guard let data = defaults.data(forKey: Self.key),
            let decoded = try? JSONDecoder().decode(RampSchedule.self, from: data)
        else {
            return RampSchedule()
        }
        return decoded
    }

    /// Writes the schedule, removing it entirely when it is back at the shipped
    /// default — so a later build changing that default is not overridden by a
    /// stale copy of the old one that the user never chose. `NudgeSettings.save`
    /// does the same, for the same reason.
    public func save(_ schedule: RampSchedule) {
        guard schedule != RampSchedule() else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        guard let data = try? JSONEncoder().encode(schedule) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
