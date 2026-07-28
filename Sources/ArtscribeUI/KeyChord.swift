import SwiftUI

/// The modifiers a chord can carry, in this app's own currency rather than
/// SwiftUI's.
///
/// `EventModifiers` is not a good source of truth: it is `OptionSet`-shaped but
/// carries members this app never binds (`.capsLock`, `.numericPad`,
/// `.function`) which macOS *sets on real events* — every arrow key arrives with
/// `.function`, and a keyboard with Caps Lock down adds `.capsLock` to
/// everything. Matching a press against a binding therefore has to normalise
/// first, and a type that can only hold the four modifiers this app binds is
/// what makes that normalisation a one-liner instead of a rule everyone has to
/// remember.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

/// One key on the keyboard, as this app's catalog names it.
///
/// A closed enum rather than a `Character`, because the keys that are not
/// letters — Space, Escape, the four arrows — have no single character a reader
/// would recognise, and because it lets `KeyChord` be `Hashable` and used as a
/// dictionary key for the reverse lookup in `KeyBindings`.
public enum KeyToken: Hashable, Sendable {
    case character(Character)
    case space
    case escape
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow

    /// How the key reads in the shortcut reference. Letters uppercase, because
    /// that is how a menu draws them and how everyone writes them down.
    public var display: String {
        switch self {
        case .character(let character): return String(character).uppercased()
        case .space: return "Space"
        case .escape: return "⎋"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        }
    }
}

/// A key plus its modifiers: one binding, in the form both the menus and the
/// shortcut reference read.
public struct KeyChord: Hashable, Sendable {
    public let key: KeyToken
    public let modifiers: KeyModifiers

    public init(_ key: KeyToken, _ modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// A letter or digit chord, which is most of them.
    public static func key(_ character: Character, _ modifiers: KeyModifiers = []) -> KeyChord {
        KeyChord(.character(character), modifiers)
    }

    /// The chord as a Mac user writes it: `⌥⌘I`, `⇧Space`, `Z`.
    ///
    /// Modifier order is Apple's own — ⌃ ⌥ ⇧ ⌘ — so a chord written here reads
    /// identically to the one the menu bar draws beside the same item.
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key.display
    }
}

// MARK: - SwiftUI

extension KeyToken {
    /// The SwiftUI key equivalent, which is what an `NSMenuItem` ends up
    /// carrying.
    ///
    /// Letters go across **lowercase** even when the chord carries ⇧. That is
    /// the form `NSMenu` matches, and it is what the Loop menu's move items
    /// already used before this consolidation; the Playback menu's `⇧Q`/`⇧W`
    /// used the uppercase form instead, which is exactly the sort of split a
    /// single catalog exists to end. Both routes reach the same action through
    /// `ActionInvoker`, so whichever of the menu and the window claims the
    /// event, it fires once and does the same thing.
    var keyEquivalent: KeyEquivalent {
        switch self {
        case .character(let character):
            return KeyEquivalent(Character(String(character).lowercased()))
        case .space: return .space
        case .escape: return .escape
        case .leftArrow: return .leftArrow
        case .rightArrow: return .rightArrow
        case .upArrow: return .upArrow
        case .downArrow: return .downArrow
        }
    }

    /// The reverse map, for turning a `KeyPress` back into a catalog token.
    /// Built from `KeyEquivalent`'s own constants rather than from hand-written
    /// `\u{F702}` escapes, so it cannot drift from what SwiftUI reports.
    static let specialsByCharacter: [Character: KeyToken] = [
        KeyEquivalent.space.character: .space,
        KeyEquivalent.escape.character: .escape,
        KeyEquivalent.leftArrow.character: .leftArrow,
        KeyEquivalent.rightArrow.character: .rightArrow,
        KeyEquivalent.upArrow.character: .upArrow,
        KeyEquivalent.downArrow.character: .downArrow
    ]
}

extension KeyModifiers {
    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if contains(.control) { result.insert(.control) }
        if contains(.option) { result.insert(.option) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.command) { result.insert(.command) }
        return result
    }

    /// The four modifiers this app binds, taken out of whatever a real event
    /// arrived with.
    ///
    /// **The arrows are why this exists.** macOS sets flags on them that
    /// nothing here binds — `.numericPad`, and the function flag every arrow
    /// carries — so an exact comparison against a binding declared as "bare ←"
    /// would never match. `.capsLock` is dropped for the same reason.
    ///
    /// `.control` is dropped rather than compared, which preserves a decision
    /// `DocumentView.handleLoop` recorded before this consolidation: nothing in
    /// the app binds ⌃, and refusing a ⌃-modified press would make the plain
    /// actions unreachable for anyone whose hand rests on the key.
    static func fromEvent(_ modifiers: EventModifiers) -> KeyModifiers {
        var result: KeyModifiers = []
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.command) { result.insert(.command) }
        return result
    }
}

extension KeyChord {
    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(key.keyEquivalent, modifiers: modifiers.eventModifiers)
    }

    /// The chord a `KeyPress` represents, normalised so it can be looked up.
    ///
    /// `character` must be `press.key.character`, not `press.characters`: with
    /// ⌥ held the latter is the dead-key composition ("´" for ⌥E on a US
    /// layout), which no binding could match.
    public static func fromPress(character: Character, modifiers: EventModifiers) -> KeyChord {
        let normalised = KeyModifiers.fromEvent(modifiers)
        if let special = KeyToken.specialsByCharacter[character] {
            return KeyChord(special, normalised)
        }
        return KeyChord(.character(Character(String(character).lowercased())), normalised)
    }
}
