import ArtscribeKit
import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#endif

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

    #if os(macOS)
    /// Told which `NSWindow` the ramp ended up in, by the view inside it.
    ///
    /// macOS only: on iPad the sheet has no window object to be told about, and
    /// `AuxiliaryWindow` tracks presentation directly instead.
    public func adopt(window: NSWindow?) { windowState.window = window }
    #endif
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
