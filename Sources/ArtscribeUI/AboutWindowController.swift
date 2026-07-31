import Foundation

#if os(macOS)
import AppKit
#endif

/// The About panel's identity, and the one way to open it.
///
/// The third of these, after `ShortcutWindowController` and
/// `PracticeWindowController`, and deliberately the thinnest: the panel holds no
/// state at all — everything it draws is a constant or comes off `Bundle.main`
/// — so there is nothing here but the window itself.
///
/// It exists for the reason the other two do: `openWindow(id:)` is an
/// `EnvironmentValues` member reachable only from inside a `View` body, while
/// `ActionInvoker`'s table is not a view on purpose. The scene hands its
/// `openWindow` over once, on appear, and the action calls it.
@MainActor
public final class AboutWindowController {
    /// The scene id, and the `NSWindow` frame-autosave name. One constant so the
    /// scene and the opener cannot disagree about which window is meant.
    public static let windowID = "about"

    /// Opening, raising, focusing and closing on macOS; presenting a sheet on
    /// iPad. Shared with the other two auxiliary windows rather than copied —
    /// see `AuxiliaryWindow`, which was extracted precisely because the second
    /// copy had both of the defects the first had been fixed for.
    public let windowState = AuxiliaryWindow()

    /// Installed by the scene. Plumbing written once at launch.
    public var present: (@MainActor () -> Void)? {
        get { windowState.present }
        set { windowState.present = newValue }
    }

    public init() {}

    public func show() { windowState.show() }

    /// **Artscribe ▸ About Artscribe**, and **Help ▸ About Artscribe**.
    ///
    /// A toggle rather than a plain show, matching `⌘/` and `⌘P`: chosen from a
    /// menu while the panel is already in front of you, a non-toggling command
    /// does nothing at all, which reads as broken. See `AuxiliaryWindow.action`.
    public func toggle() { windowState.toggle() }

    #if os(macOS)
    /// Told which `NSWindow` the panel ended up in, by the view inside it —
    /// without it the toggle has no window to ask and could only ever open.
    ///
    /// macOS only: on iPad the panel is a sheet with no window object to be told
    /// about, and `AuxiliaryWindow` tracks presentation directly instead.
    public func adopt(window: NSWindow?) { windowState.window = window }
    #endif
}
