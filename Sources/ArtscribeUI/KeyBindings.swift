/// The keyboard, as a reverse index of `ActionCatalog`.
///
/// The window used to answer for the keys itself, in eight `handle…` methods
/// whose `switch`es spelled out `"z"`, `"x"`, `"a"`…`"g"` a second time beside
/// the menus that also declared them. That is one of the three places a
/// shortcut lived, and the one no test could see.
///
/// Now there is one table and this reads it backwards. A chord that is not in
/// the catalog resolves to nothing, which is the point: before this,
/// `DocumentView.handleVolume` matched `M` while *ignoring every modifier*, so
/// `⇧M` and `⌥M` were live bindings that no menu, README or spec named — the
/// exact drift this task exists to end. `KeyBindingsTests` asserts the
/// round trip in both directions.
///
/// This is also what spec §6.3's rebindable `BindingTable` replaces when it
/// lands: the same lookup, from a persisted table rather than a fixed one.
public enum KeyBindings {

    /// Every chord in the catalog, pointing at the action it invokes.
    ///
    /// A duplicate resolves to whichever action declared it first, and is
    /// caught by `noTwoActionsShareAChord` rather than trapped here. That was a
    /// deliberate second choice: `uniqueKeysWithValues` traps, which aborts the
    /// whole test run at the first duplicate instead of letting the suite report
    /// which chord and which two actions — and in a shipping app it would turn a
    /// typo in the catalog into a crash on the first key press.
    static let byChord: [KeyChord: ActionID] = Dictionary(
        ActionCatalog.entries.flatMap { entry in entry.chords.map { ($0, entry.id) } },
        uniquingKeysWith: { first, _ in first })

    public static func action(for chord: KeyChord) -> ActionID? { byChord[chord] }

    /// What the **window** should do with a press, as opposed to what the menu
    /// bar has already had its chance at.
    ///
    /// `⌘` chords are refused outright. AppKit offers a key event to the menu
    /// bar before the window, so anything carrying Command has already been
    /// claimed there if it was going to be; answering it here as well would be
    /// a second implementation of the same action.
    ///
    /// Everything else is answered whether or not a menu item also declares it.
    /// That is not belt and braces: `NSMenu` matches a key equivalent against a
    /// **lowercase** `charactersIgnoringModifiers`, so a `⇧A` arriving as "A" is
    /// never claimed by the menu at all, and without this the twelve loop-move
    /// items would draw their shortcuts and none of them would fire. A claimed
    /// event never reaches the window, so nothing fires twice.
    public static func windowAction(for chord: KeyChord) -> ActionID? {
        guard !chord.modifiers.contains(.command) else { return nil }
        return action(for: chord)
    }
}
