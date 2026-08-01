import Foundation
import Observation
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

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

    /// The appearance this preference names outright, or `nil` for `system`,
    /// which names none: it has to be resolved against what macOS is set to.
    ///
    /// Deliberately *not* a `ColorScheme?` that hands `nil` to
    /// `preferredColorScheme`. That is what this type used to be, and it is the
    /// whole bug — see `ThemeController.appearance`.
    var explicitAppearance: Appearance? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    #if os(macOS)
    /// `nil` means "whatever macOS is set to", which is what
    /// `NSApplication.appearance` takes as its follow-the-system value. Unlike
    /// SwiftUI's `preferredColorScheme`, AppKit honours the `nil` properly.
    ///
    /// macOS only, and there is deliberately no iOS counterpart: the thing this
    /// exists to drive — `NSApp.appearance`, which reaches the menu bar, the
    /// open panel and the title bar — has no equivalent on iOS, where every
    /// pixel the app shows is SwiftUI's.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    #endif
}

/// Holds the theme preference, resolves it, and makes it stick.
///
/// Deliberately a small standalone `@Observable` rather than something wired
/// into `ViewerModel`: the theme is a property of the application, not of the
/// loaded track, and the Settings window binds to the same object the menu
/// used to.
///
/// ## Why `System` is resolved here instead of by SwiftUI
///
/// `preferredColorScheme(nil)` is documented to mean "follow the system", and
/// it half does: it correctly clears the override off `NSWindow`, so the title
/// bar and the menu bar return to the system appearance. But **SwiftUI does not
/// re-derive the `\.colorScheme` environment value for the subtree** — it
/// leaves it on the last non-`nil` scheme it was given. Measured on macOS 26.5
/// with the system in light mode:
///
/// ```
/// [dark]              env.colorScheme=dark  window.effective=NSAppearanceNameDarkAqua
/// [system after dark] env.colorScheme=dark  window.effective=NSAppearanceNameAqua
/// ```
///
/// Everything Artscripture draws itself goes through `Palette.of(appearance)`,
/// and `DocumentView` derives that `appearance` from `\.colorScheme`. So the
/// window chrome went light while the entire contents stayed dark — which is
/// what "System does not restore the system appearance" looks like from the
/// user's chair.
///
/// The defect is invisible whenever the last explicit theme and the system
/// agree, which is why it survived review on a Mac in dark mode.
///
/// The fix is to never hand SwiftUI a `nil`: resolve `system` against macOS
/// here and pass an explicit `ColorScheme` always. That costs this type an
/// observer for the system switch, which is the plumbing the old comment
/// claimed SwiftUI was providing for free.
@MainActor
@Observable
public final class ThemeController {
    /// Dark, not System, with nothing stored yet: it is the look the app was
    /// designed around, and it is what the window did before this preference
    /// existed. Following the system by default would silently change the app
    /// for anyone whose Mac is in light mode, which is not a change to make on
    /// their behalf — `System` is one control away for anyone who wants it.
    public static let fallback: ThemePreference = .dark

    private static let defaultsKey = "theme"

    /// The global light/dark switch, as a distributed notification. Undocumented
    /// but long-standing, and — unlike KVO on `NSApp.effectiveAppearance` — it
    /// still fires while this app is overriding its own appearance, because it
    /// is about the system rather than about us.
    private static let systemAppearanceDidChange = Notification.Name(
        "AppleInterfaceThemeChangedNotification")

    private let defaults: UserDefaults
    private let readSystemAppearance: @MainActor () -> Appearance
    /// `@ObservationIgnored` because nothing observes an opaque token, and
    /// because without it the macro turns this into a computed property that
    /// `nonisolated(unsafe)` cannot describe. `nonisolated(unsafe)` so `deinit`,
    /// which is not main-actor isolated, can hand the token back: it is written
    /// once during `init` and read once during `deinit`, by which point no other
    /// reference to this object survives, so there is nothing to race with.
    @ObservationIgnored private nonisolated(unsafe) var systemObserver: (any NSObjectProtocol)?

    public var preference: ThemePreference {
        didSet {
            guard preference != oldValue else { return }
            defaults.set(preference.rawValue, forKey: Self.defaultsKey)
            applyToApplication()
        }
    }

    /// What macOS itself is set to, cached so that a change to it invalidates
    /// the views that read `appearance`.
    public private(set) var systemAppearance: Appearance

    /// The appearance actually to be drawn — the preference with `system`
    /// resolved. This is what the window applies and what everything else
    /// should ask for.
    public var appearance: Appearance { preference.explicitAppearance ?? systemAppearance }

    /// The same answer in SwiftUI's currency. Non-optional on purpose: see the
    /// type's documentation for what handing `preferredColorScheme` a `nil`
    /// actually does.
    public var colorScheme: ColorScheme { appearance == .dark ? .dark : .light }

    /// - Parameters:
    ///   - defaults: injectable so tests get their own suite instead of writing
    ///     into the user's real preferences.
    ///   - systemAppearance: injectable so the resolution of `system` can be
    ///     driven in *both* directions from a test. Reading the real machine
    ///     would make the check vacuous in whichever mode the machine happens
    ///     to be in — which is exactly how this bug shipped.
    public init(
        defaults: UserDefaults = .standard,
        systemAppearance readSystem: @escaping @MainActor () -> Appearance = ThemeController
            .macOSAppearance
    ) {
        self.defaults = defaults
        readSystemAppearance = readSystem
        systemAppearance = readSystem()
        let stored = defaults.string(forKey: Self.defaultsKey)
        preference = stored.flatMap(ThemePreference.init(rawValue:)) ?? Self.fallback
        // macOS only. The notification is `AppleInterfaceThemeChangedNotification`
        // on the *distributed* centre, which is a Mac IPC mechanism with no iOS
        // equivalent — iOS delivers a trait change to the view hierarchy instead.
        // See `readSystemAppearance` for how the two platforms answer the same
        // question, and `refreshSystemAppearance` for when iOS re-asks it.
        #if os(macOS)
        systemObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.systemAppearanceDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemAppearance() }
        }
        #endif
    }

    deinit {
        #if os(macOS)
        if let systemObserver {
            DistributedNotificationCenter.default().removeObserver(systemObserver)
        }
        #endif
    }

    /// What macOS itself is set to, read from the global `AppleInterfaceStyle`
    /// default rather than from `NSApp.effectiveAppearance`.
    ///
    /// That distinction is load-bearing. `applyToApplication` sets
    /// `NSApp.appearance` for Light and Dark, so `NSApp.effectiveAppearance`
    /// reads back *this app's own override* rather than the system's. The
    /// global default is not touched by that: measured returning `Dark` with
    /// the app forced to Aqua, and `nil` with the app forced to Dark Aqua.
    /// On iOS the same question is asked of the current trait collection, which
    /// is the platform's own answer and needs no equivalent caveat: iOS has no
    /// application-wide appearance override for it to be confused by.
    public static func macOSAppearance() -> Appearance {
        #if os(macOS)
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            ? .dark : .light
        #else
        return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
        #endif
    }

    /// Re-read macOS's setting. Called on the system-appearance notification and
    /// whenever the preference is applied.
    public func refreshSystemAppearance() {
        systemAppearance = readSystemAppearance()
    }

    /// The menu bar, the open panel and the window's title bar are AppKit's, not
    /// SwiftUI's, and `preferredColorScheme` does not reach them. Setting the
    /// application appearance does, and agrees with it.
    /// A no-op on iOS, and correctly so rather than for want of an API: there is
    /// no menu bar, no open panel and no title bar to reach, so
    /// `preferredColorScheme` already covers everything the app draws.
    public func applyToApplication() {
        #if os(macOS)
        NSApp?.appearance = preference.nsAppearance
        #endif
        // Belt and braces for the cached value: if the notification above ever
        // stops arriving, `System` is still right at the moment it is chosen,
        // and only live-following would be lost.
        refreshSystemAppearance()
    }
}
