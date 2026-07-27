import AppKit
import Foundation
import Observation
import SwiftUI

/// What the user chose, as opposed to what is on screen: `system` resolves to
/// one of the two `Appearance`s and follows macOS as it changes.
public enum ThemePreference: String, Equatable, Sendable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` means "whatever macOS is set to", which is exactly what both
    /// `preferredColorScheme` and `NSApplication.appearance` take as their
    /// follow-the-system value.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Holds the theme preference and makes it stick.
///
/// Deliberately a small standalone `@Observable` rather than something wired
/// into `ViewerModel`: the theme is a property of the application, not of the
/// loaded track, and the Settings window (Task 14) needs to bind to the same
/// object the menu does. Moving the control into Settings later means pointing a
/// `@Bindable` at this and deleting a menu — no state moves.
///
/// The *resolved* appearance is not stored here. SwiftUI already resolves it:
/// the window applies `colorScheme`, and `DocumentView` reads the environment's
/// `\.colorScheme` back out, so `system` tracks macOS with no notification
/// plumbing of its own.
@MainActor
@Observable
public final class ThemeController {
    /// The dark theme is the default the app was designed around, but a first
    /// launch with no stored preference follows the system — a user in light
    /// mode should not be handed a dark window without asking.
    public static let fallback: ThemePreference = .system

    private static let defaultsKey = "theme"

    private let defaults: UserDefaults

    public var preference: ThemePreference {
        didSet {
            guard preference != oldValue else { return }
            defaults.set(preference.rawValue, forKey: Self.defaultsKey)
            applyToApplication()
        }
    }

    /// - Parameter defaults: injectable so tests get their own suite instead of
    ///   writing into the user's real preferences.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.defaultsKey)
        preference = stored.flatMap(ThemePreference.init(rawValue:)) ?? Self.fallback
    }

    public var colorScheme: ColorScheme? { preference.colorScheme }

    /// The menu bar, the open panel and the window's title bar are AppKit's, not
    /// SwiftUI's, and `preferredColorScheme` does not reach them. Setting the
    /// application appearance does, and agrees with it.
    public func applyToApplication() {
        NSApp?.appearance = preference.nsAppearance
    }
}
