import SwiftUI

/// The title a menu item and the shortcut window both draw.
///
/// The base words live in `ActionCatalog`; this adds only what has to be live —
/// the transport's state, the engine's, and the amounts the nudge and move
/// tiers are currently set to.
///
/// The amounts are in the titles rather than only in Settings for two reasons:
/// the menu is where you look to find out what a key does, and it is the only
/// place a Settings change is visible without pressing the key and guessing.
@MainActor
public enum ActionTitle {
    public static func display(_ id: ActionID, _ context: MenuContext) -> String {
        live[id]?(context) ?? reference(id, context)
    }

    /// The same title for the shortcut window's list, minus the two that name
    /// a live *state*.
    ///
    /// "Pause" and "Use Studio Engine — now: Fast" are the right words on a menu
    /// item, which is a thing you are about to press. In a reference they read
    /// as though the shortcut only does half of what it does, so the window gets
    /// the catalog's own wording — with the amounts, which are what a reader
    /// most wants to check.
    public static func reference(_ id: ActionID, _ context: MenuContext) -> String {
        let base = ActionCatalog.entry(id).title
        guard let amount = amountLabel(id, context) else { return base }
        return base + " " + amount
    }

    private static func amountLabel(_ id: ActionID, _ context: MenuContext) -> String? {
        if let tier = nudgeTiers[id] {
            return NudgeAmounts.label(seconds: context.model.nudgeAmounts[tier])
        }
        if let tier = moveTiers[id] {
            return NudgeAmounts.label(seconds: context.model.selectionMoveAmounts[tier])
        }
        return nil
    }

    private static let nudgeTiers: [ActionID: NudgeTier] = [
        .nudgeBack: .normal, .nudgeForward: .normal,
        .nudgeBackFine: .fine, .nudgeForwardFine: .fine,
        .nudgeBackCoarse: .coarse, .nudgeForwardCoarse: .coarse
    ]

    private static let moveTiers: [ActionID: SelectionMoveTier] = [
        .selectionMoveLeft: .gentle, .selectionMoveRight: .gentle,
        .selectionMoveLeftFar: .aggressive, .selectionMoveRightFar: .aggressive,
        .loopMoveInLeft: .gentle, .loopMoveInRight: .gentle,
        .loopMoveInLeftFar: .aggressive, .loopMoveInRightFar: .aggressive,
        .loopMoveOutLeft: .gentle, .loopMoveOutRight: .gentle,
        .loopMoveOutLeftFar: .aggressive, .loopMoveOutRightFar: .aggressive,
        .loopMoveLeft: .gentle, .loopMoveRight: .gentle,
        .loopMoveLeftFar: .aggressive, .loopMoveRightFar: .aggressive
    ]

    /// The two titles that name a *state* rather than an action.
    ///
    /// The engine item says which engine is running now, because "Studio /
    /// Fast" alone leaves you guessing which half is current. It is set off
    /// with a dash rather than `"  (now: Studio)"`: "no menu title contains
    /// `  (`" is the one-line rule the acceptance run uses to prove no shortcut
    /// is spelled into a title, and it is only worth having with no exceptions.
    private static let live: [ActionID: @MainActor (MenuContext) -> String] = [
        .transportPlayPause: { $0.model.isPlaying ? "Pause" : "Play" },
        .speedEngineToggle: {
            $0.model.speed.engine == .studio
                ? "Use Fast Engine — now: Studio" : "Use Studio Engine — now: Fast"
        }
    ]
}

/// Whether a menu item is live, from the policy on its catalog row.
///
/// One rule per policy, so the same condition cannot be spelled two ways in two
/// menus. `documentIsKey` is passed in rather than read here so the caller
/// reads it inside a `View` body, which is what makes it track.
@MainActor
enum ActionAvailability {
    static func isEnabled(_ id: ActionID, _ context: MenuContext, documentIsKey: Bool) -> Bool {
        let model = context.model
        let ready = model.hasTrack && documentIsKey
        switch ActionCatalog.entry(id).enablement {
        case .always: return true
        case .documentKey: return documentIsKey
        case .track: return ready
        case .trackPlaying: return ready && model.isPlaying
        case .trackLoopToggle: return ready && !(model.loop.range.isEmpty && !model.loop.isEnabled)
        case .trackLoop: return ready && !model.loop.range.isEmpty
        case .trackSelection: return ready && !model.selection.isEmpty
        }
    }
}

/// One menu item, drawn from its catalog row.
///
/// **A `View`, never a bare `Commands` body.** A `Commands` body is not
/// re-evaluated when an `@Observable` model changes, so a `.disabled(…)`
/// written there goes stale — ⌘9 measurably stopped firing in Task 10 because
/// the item was still marked disabled from launch. A `View` nested inside a
/// `CommandGroup` tracks its own observation and updates while the menu is
/// open, which is what makes the greying-out below real.
struct ActionMenuItem: View {
    let id: ActionID
    let context: MenuContext
    /// Read inside this `View` body so the items re-evaluate when the key
    /// window changes.
    private let keyWindow = KeyWindowTracker.shared

    var body: some View {
        let entry = ActionCatalog.entry(id)
        Group {
            if entry.kind == .toggle {
                Toggle(ActionTitle.display(id, context), isOn: toggleBinding)
            } else {
                Button(ActionTitle.display(id, context)) { ActionInvoker.perform(id, context) }
            }
        }
        // An `NSMenuItem` holds exactly one key equivalent, so the menu draws
        // the first chord. `KeyBindings` answers for the rest — the arrows the
        // nudge tiers also take, and every ⇧-letter `NSMenu` refuses to match.
        .keyboardShortcut(entry.primaryChord?.keyboardShortcut)
        .disabled(
            !ActionAvailability.isEnabled(id, context, documentIsKey: keyWindow.documentIsKey))
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { ActionInvoker.isOn(id, context) ?? false },
            set: { ActionInvoker.setOn(id, $0, context) })
    }
}

/// A whole menu-bar group, rendered from `MenuPlan`.
///
/// This is what makes the drift guard mean something: a menu item cannot exist
/// without a plan entry, and a plan entry cannot name an action the catalog
/// does not have.
struct MenuItems: View {
    let section: MenuSection
    let context: MenuContext

    var body: some View {
        // Indexed rather than keyed by the entry: a section holds several
        // separators, and `ForEach` needs them told apart.
        ForEach(Array(MenuPlan.entries(for: section).enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .action(let id):
                ActionMenuItem(id: id, context: context)
            case .separator:
                Divider()
            case .dynamicSubmenu(.openRecent):
                RecentFilesMenu(model: context.model, recents: context.recents)
            case .dynamicSubmenu(.outputDevice):
                OutputDeviceMenu(devices: context.devices)
            }
        }
    }
}
