/// **The modifier layers**, and the rule for which one is showing.
///
/// One keyboard cannot draw this keymap. `Z` nudges, `⇧Z` nudges finely, `⌥Z`
/// rewinds; `A` sets the loop in point, `⇧A` moves it, `⌥⇧A` moves it far. Six
/// different things live on the `A` and `Z` caps alone, and a picture that
/// stacked them would teach nothing.
///
/// So the keyboard shows **one layer at a time** and changes layer as you hold
/// the modifier — which is not decoration: it is the same gesture as using the
/// app, performed against a picture that answers back. Holding `⌥⇧` and
/// watching `A S D F` turn from "set the loop edge here" into "move the loop
/// edge far" is the keymap explaining its own shape.
///
/// Holding two keys at once is not something everyone can do, so a layer can
/// also be **pinned** from the picker and stays until it is changed. That is an
/// accessibility requirement rather than a nicety, and `effective(held:pinned:)`
/// is the whole of the rule: hold wins while you hold, pin is what you come
/// back to.
public enum ShortcutLayers {

    /// Every modifier combination the catalog actually uses, simplest first,
    /// with the unmodified layer always at the head.
    ///
    /// **Derived, not listed.** A chord bound on a combination nobody thought
    /// of still gets a layer to be seen on, and a layer whose chords are all
    /// removed stops being offered. A hand-written list here would be the
    /// second source of truth this window exists to avoid.
    public static let available: [KeyModifiers] = {
        var combinations = Set(ActionCatalog.entries.flatMap(\.chords).map(\.modifiers))
        combinations.insert([])
        return combinations.sorted { first, second in
            let counts = (first.rawValue.nonzeroBitCount, second.rawValue.nonzeroBitCount)
            guard counts.0 == counts.1 else { return counts.0 < counts.1 }
            return order(first) < order(second)
        }
    }()

    /// Within a rank, `⇧` before `⌥` before `⌘` — the order the modifiers are
    /// reached for, not the bit order of `KeyModifiers`.
    private static func order(_ modifiers: KeyModifiers) -> Int {
        var score = 0
        if modifiers.contains(.shift) { score += 1 }
        if modifiers.contains(.option) { score += 10 }
        if modifiers.contains(.command) { score += 100 }
        if modifiers.contains(.control) { score += 1000 }
        return score
    }

    /// What the layer is called in the picker. The unmodified layer is named
    /// rather than left blank, because a picker with an empty first segment
    /// reads as a bug.
    public static func title(_ modifiers: KeyModifiers) -> String {
        guard !modifiers.isEmpty else { return "Base" }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text
    }

    /// The layer on screen, given what is being held and what is pinned.
    ///
    /// Holding wins while it lasts and the pin is what letting go returns to.
    /// A held combination that nothing is bound on — `⇧⌘⌥`, say — is still
    /// shown, as an empty keyboard: that is the honest answer to "what does
    /// this do", and pretending it was the base layer would be a lie about
    /// which keys are live.
    public static func effective(held: KeyModifiers, pinned: KeyModifiers) -> KeyModifiers {
        held.isEmpty ? pinned : held
    }

    /// What every key does on one layer: the catalog's chords carrying exactly
    /// these modifiers, indexed by the key they sit on.
    ///
    /// Exactly, not "at least": `Z` and `⇧Z` are different actions, so the base
    /// layer must not show the shifted one. A key can hold at most one action
    /// per layer — `noTwoActionsShareAChord` is what guarantees that, and
    /// `bindingsPerLayer` checks the count here so a collision cannot be
    /// silently swallowed by the dictionary.
    public static func bindings(on layer: KeyModifiers) -> [KeyToken: ActionEntry] {
        var result: [KeyToken: ActionEntry] = [:]
        for entry in ActionCatalog.entries {
            for chord in entry.chords where chord.modifiers == layer {
                result[chord.key] = entry
            }
        }
        return result
    }
}
