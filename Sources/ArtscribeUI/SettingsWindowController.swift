import Foundation

/// The Settings sheet's identity, and the one way to open it — **on iPad**.
///
/// ## Why this exists on only one platform
///
/// macOS has no need of it: SwiftUI's `Settings` scene owns both the
/// **Artscripture ▸ Settings…** menu item and `⌘,`, which is why
/// `ActionInvokerTable` has no entry for `.appSettings` there. iPadOS has no
/// such scene, and the `Settings…` the system offers goes to the app's page in
/// the Settings app — which is empty, because this app ships no
/// `Settings.bundle`. So on iPad the settings were not hidden or broken; there
/// was simply no surface, and that is what a tester found.
///
/// It is declared unconditionally rather than behind `#if !os(macOS)` so that
/// `MenuContext` stays one shape on both platforms. On macOS it is **inert, and
/// correctly inert rather than a stub**: nothing calls `show()`, and the
/// `Settings` scene continues to own the menu item — the same arrangement
/// `UnmanagedAudioSession` has for interruptions.
///
/// ## Why a sheet and not a `Settings.bundle`
///
/// These are *working* settings. The nudge amounts and the preroll get tuned
/// while transcribing, and leaving the app mid-practice to change one is the
/// wrong trade — Apple's own guidance puts frequently-changed settings in the
/// app. A `Settings.bundle` also offers only four widget types, gives no live
/// feedback while a slider moves, and would restate every default in a
/// `Root.plist` that has to be kept in step with the Swift settings types by
/// hand. Two declarations of the same default drift, and silently.
@MainActor
public final class SettingsWindowController {
    /// Kept for symmetry with the other auxiliary controllers, and unused on
    /// macOS where the `Settings` scene has its own window.
    public static let windowID = "settings"

    /// Shared with the About panel, the shortcut reference and Practice rather
    /// than copied — see `AuxiliaryWindow`, which was extracted because the
    /// second copy of this logic had both defects the first had been fixed for.
    public let windowState = AuxiliaryWindow()

    public init() {}

    public func show() { windowState.show() }

    /// A toggle rather than a plain show, for the reason `⌘/` and `⌘P` are:
    /// invoked while the sheet is already up, a non-toggling command does
    /// nothing at all, which reads as broken.
    public func toggle() { windowState.toggle() }
}
