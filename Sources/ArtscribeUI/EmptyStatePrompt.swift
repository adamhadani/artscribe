#if !os(macOS)
import UIKit
#endif

/// What the resting screen offers, per platform.
///
/// "Drop an audio file here" is a **Mac sentence**. It survived onto iPhone,
/// where it is not merely unidiomatic but *false*: dragging a file in from Files
/// needs two apps on screen at once, and iPhone has no Split View. A first-time
/// user was being told to do something the device cannot do.
///
/// iPad keeps it, because there the drop genuinely works — Slide Over and Split
/// View make it an ordinary gesture, and `DocumentView` already accepts it.
///
/// Pure, and keyed on an explicit case rather than `#if`, so all three readings
/// are checkable from one test run instead of one per platform build. That
/// matters here: the wrong string only appears on the platform the author is not
/// using, which is exactly how this shipped.
public enum EmptyStatePrompt {

    /// Which sentence to use. Named for the *interaction* rather than the OS,
    /// because that is what decides it: whether a file can be dragged in.
    public enum Surface {
        /// A pointer, a file system in a window, and drag-and-drop.
        case desktop
        /// Touch, with multitasking — a drop is possible and normal.
        case tabletWithDrop
        /// Touch, one app at a time. Nothing can be dragged in.
        case phone
    }

    public static func headline(for surface: Surface) -> String {
        switch surface {
        case .desktop, .tabletWithDrop: return "Drop an audio file here"
        case .phone: return "No track open"
        }
    }

    public static func hint(for surface: Surface) -> String {
        switch surface {
        // ⌘O is only advice where there is a keyboard to press it on.
        case .desktop: return "or press ⌘O to choose one"
        case .tabletWithDrop: return "or use Open… above"
        // Not "or": on a phone this is the only way in, and "or" implies a
        // second route the user should be able to find.
        case .phone: return "Use Open… above to choose one"
        }
    }

    /// How to make a loop, when the Practice panel finds there is none.
    ///
    /// **The worst offender of its class.** It used to read *"press A … press S
    /// … press G"*, and it is shown precisely when someone is stuck — so on a
    /// touch device every instruction it gave was impossible, at the one moment
    /// the user was reading carefully.
    public static func loopGuidance(for surface: Surface) -> String {
        switch surface {
        case .desktop:
            return "Put the playhead where the passage starts and press A, then where it "
                + "ends and press S. Or drag a selection and press G to turn it into a loop."
        case .tabletWithDrop, .phone:
            // The transport's Selection → Loop button is the touch route, and
            // naming it is the whole point: it exists because there was none.
            return "Drag across the waveform to select the passage, then tap "
                + "Selection → Loop in the transport bar."
        }
    }

    /// How to open a track, when there is none.
    public static func openGuidance(for surface: Surface) -> String {
        switch surface {
        case .desktop: return "File ▸ Open… (⌘O), or drop an audio file on the window."
        case .tabletWithDrop: return "Tap Open… above, or drop an audio file on the window."
        case .phone: return "Tap Open… above to choose a track."
        }
    }

    /// The surface this build is running on.
    ///
    /// `@MainActor` because `UIDevice.current` is — the same isolation that
    /// `make ios-check` cannot catch, since it compiles `Playback` alone and
    /// never sees this module. Build the iPad scheme when changing it.
    @MainActor
    public static var current: Surface {
        #if os(macOS)
        return .desktop
        #else
        return UIDevice.current.userInterfaceIdiom == .phone ? .phone : .tabletWithDrop
        #endif
    }
}
