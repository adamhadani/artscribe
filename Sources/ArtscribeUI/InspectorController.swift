import Foundation
import Observation

/// A page of the inspector.
///
/// An enum with one case today, and that is on purpose: the Practice hub lands
/// here next, so the container is built to hold more than one page rather than
/// being a shortcut panel that has to be reopened as something else later.
public enum InspectorPage: String, CaseIterable, Hashable, Sendable, Identifiable {
    case shortcuts

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .shortcuts: return "Shortcuts"
        }
    }

    /// The SF Symbol for the page picker, once there is more than one page to
    /// pick between.
    public var symbol: String {
        switch self {
        case .shortcuts: return "keyboard"
        }
    }
}

/// Whether the inspector is showing, and which page.
///
/// Spec §2 and §6.2 have specified a collapsible inspector since the design was
/// approved; this is its state, and it is the **fourth** documented-but-unbuilt
/// feature the user found rather than a review.
///
/// A small standalone `@Observable`, following `ThemeController`: the inspector
/// is a property of the application rather than of the loaded track, and both
/// the View menu and the window need to reach it.
@MainActor
@Observable
public final class InspectorController {
    private static let presentedKey = "inspector.isPresented"
    private static let pageKey = "inspector.page"

    private let defaults: UserDefaults

    /// Persisted, so an inspector left open is open next launch.
    ///
    /// Closed by default: the waveform is what this app is for, and a panel
    /// that appears uninvited on first run takes width from it before the user
    /// has any reason to want the panel.
    public var isPresented: Bool {
        didSet {
            guard isPresented != oldValue else { return }
            defaults.set(isPresented, forKey: Self.presentedKey)
        }
    }

    public var page: InspectorPage {
        didSet {
            guard page != oldValue else { return }
            defaults.set(page.rawValue, forKey: Self.pageKey)
        }
    }

    /// - Parameter defaults: injectable so tests get their own suite instead of
    ///   writing into the user's real preferences.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isPresented = defaults.bool(forKey: Self.presentedKey)
        page =
            defaults.string(forKey: Self.pageKey).flatMap(InspectorPage.init(rawValue:))
            ?? .shortcuts
    }

    /// `⌥⌘I` — spec §6.2's `view.toggleInspector`. Shows and hides, leaving the
    /// page where it was.
    public func toggle() {
        isPresented.toggle()
    }

    /// `⌘/` — opens the inspector *to a page*, and closes it again if that page
    /// is already the one showing.
    ///
    /// The second half is what makes a single key honest. `⌘/` is the key
    /// people press for "show me the shortcuts", and a key that only ever opens
    /// leaves you reaching for a different one to put it away.
    public func show(_ page: InspectorPage) {
        guard isPresented, self.page == page else {
            self.page = page
            isPresented = true
            return
        }
        isPresented = false
    }
}
