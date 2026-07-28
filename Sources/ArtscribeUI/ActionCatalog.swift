/// When a menu item for an action is available.
///
/// A policy rather than a closure per item, so the same rule cannot be spelled
/// two different ways in two menus — which is how ⌘9 came to be permanently
/// disabled in Task 10.
///
/// Every one of these is evaluated inside a `View` body (`ActionMenuItem`),
/// never in a `Commands` body: a `Commands` body is not re-evaluated when an
/// `@Observable` model changes, so an enablement written there goes stale and
/// the shortcut silently stops firing.
public enum ActionEnablement: Hashable, Sendable {
    /// Always live. Every `⌘`-modified item is this: it cannot collide with
    /// typing, and the action underneath is a guarded no-op with no track.
    case always
    /// Live only while the document window is the one taking keys. This is what
    /// keeps a plain-letter key equivalent from stealing a keystroke meant for
    /// a text field in Settings — a menu key equivalent is offered *before* the
    /// key window's first responder, and a disabled item claims nothing.
    case documentKey
    /// The above, plus a track being loaded.
    case track
    /// A track, and something playing.
    case trackPlaying
    /// A track, and a loop that can be toggled — one with a region, or one
    /// already enabled.
    case trackLoopToggle
    /// A track, and a loop region that is not empty.
    case trackLoop
    /// A track, and a selection that is not empty.
    case trackSelection
}

/// Whether the menu draws a button or a checkmark for this action.
public enum ActionKind: Hashable, Sendable {
    case button
    /// Shown with a checkmark. macOS's way of saying which of a set of
    /// mutually exclusive values is active, or that a mode is on.
    case toggle
}

/// One action: its identity, how it reads, where it lives, and what it answers
/// to.
///
/// This is the row of the single table that both the menu builders and the
/// shortcut reference read. Changing a shortcut here changes it in the menu, in
/// the window's key handler and in the reference at once — which is the whole
/// point of the type existing.
public struct ActionEntry: Hashable, Sendable, Identifiable {
    public let id: ActionID
    /// The base title. Some items append a live amount or name the state they
    /// would switch to — see `ActionTitle`, which is the only place that
    /// happens.
    public let title: String
    public let category: ActionCategory
    /// Every chord this action answers to, most-canonical first.
    ///
    /// More than one is normal: the normal nudge answers to `Z`/`X` *and* to
    /// `←`/`→`. An `NSMenuItem` holds exactly one key equivalent, so the menu
    /// draws `chords.first`; the window handler and the reference use them all.
    public let chords: [KeyChord]
    /// The menu-bar group this action is placed in, or `nil` for the handful
    /// that this app does not place itself (see `ActionCatalog.notInOurMenus`).
    public let menu: MenuSection?
    public let enablement: ActionEnablement
    public let kind: ActionKind
    /// A short qualification shown under the item in the reference — "amount
    /// configurable in Settings", "in text fields". `nil` for most.
    public let note: String?

    public init(
        _ id: ActionID,
        _ title: String,
        _ category: ActionCategory,
        chords: [KeyChord] = [],
        menu: MenuSection?,
        enablement: ActionEnablement = .always,
        kind: ActionKind = .button,
        note: String? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.chords = chords
        self.menu = menu
        self.enablement = enablement
        self.kind = kind
        self.note = note
    }

    /// What the menu draws beside the item, and what the reference shows first.
    public var primaryChord: KeyChord? { chords.first }
}

/// **The single source of truth for what this app can be told to do.**
///
/// Read by three things and written by none of them:
///
/// * the menu builders, through `MenuPlan` and `ActionMenuItem` — every title,
///   every key equivalent and every enablement in the menu bar comes from here;
/// * the window's key handler, through `KeyBindings`, which is a reverse index
///   of these chords; and
/// * the shortcut window, which draws these rows onto a keyboard by chord and
///   lists them by category beside it.
///
/// It exists because this project's characteristic failure is drift: five
/// features have shipped where the spec and the code disagreed, and every one
/// was found by the user rather than by a review. A shortcut reference that
/// lies would be the worst of them, because its entire purpose is to be
/// believed. `ActionCatalogTests` is the guard — see
/// `everyCatalogActionAppearsInExactlyOneMenu`.
public enum ActionCatalog {
    /// The actions this app deliberately does not place in a menu of its own,
    /// and why. The drift guard checks this set explicitly rather than allowing
    /// a `nil` menu to mean "not checked".
    public static let notInOurMenus: Set<ActionID> = [
        // SwiftUI's `Settings` scene puts this in the **app** menu and wires ⌘,
        // to it. Declaring it a second time would give the menu bar two.
        .appSettings
    ]

    public static let entries: [ActionEntry] = allEntries

    /// First-wins on a duplicated id rather than trapping, for the reason
    /// `KeyBindings.byChord` records: a trap here would abort the whole test run
    /// before `everyActionHasExactlyOneEntry` could name the offending id, and
    /// would crash a shipping app on a typo.
    private static let byID: [ActionID: ActionEntry] = Dictionary(
        entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    /// The row for an action.
    ///
    /// Not optional: every `ActionID` has exactly one entry, which
    /// `everyActionHasExactlyOneEntry` asserts. A lookup that could return
    /// `nil` would let a missing row degrade into a menu item with no shortcut
    /// rather than into a failing test.
    public static func entry(_ id: ActionID) -> ActionEntry {
        guard let entry = byID[id] else {
            preconditionFailure("no catalog entry for \(id.rawValue)")
        }
        return entry
    }

    public static func chord(_ id: ActionID) -> KeyChord? { entry(id).primaryChord }

    // The grouping the reference draws used to live here as `reference`, and
    // skipped any action with no chord. Task 25 moved it to `ShortcutSearch`,
    // which has to filter as well as group — and stopped skipping the unbound
    // ones, because a window headed "Keyboard Shortcuts" that cannot find Stop
    // at all sends you hunting through the menu bar for it.
}
