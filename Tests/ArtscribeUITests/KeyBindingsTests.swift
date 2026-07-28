import SwiftUI
import Testing

@testable import ArtscribeUI

/// The keyboard half of the drift guard.
///
/// Before this task the window answered for the keys in eight `handle…` methods
/// whose `switch`es spelled the letters out a second time, beside the menus that
/// declared the same chords. Nothing checked that the two agreed, and they did
/// not: `M` was matched while *every modifier was ignored*, so `⇧M` and `⌥M`
/// muted; `1`–`4` likewise, so `⌥3` set a preset. Those were live bindings no
/// menu, README or spec named.
///
/// The window now resolves a press through `KeyBindings`, which is
/// `ActionCatalog` read backwards, so these assert the round trip.
@Suite("Key bindings")
struct KeyBindingsTests {

    @Test("every catalog chord resolves back to its own action")
    func everyChordRoundTrips() {
        for entry in ActionCatalog.entries {
            for chord in entry.chords {
                #expect(
                    KeyBindings.action(for: chord) == entry.id,
                    "\(chord.display) should resolve to \(entry.id.rawValue)")
            }
        }
    }

    /// ⌘ chords belong to the menu bar, which AppKit offers the event to first.
    /// Answering them from the window as well would be a second implementation
    /// of the same action.
    @Test("the window refuses every ⌘ chord and answers the rest")
    func theWindowLeavesCommandToTheMenuBar() {
        for entry in ActionCatalog.entries {
            for chord in entry.chords {
                let resolved = KeyBindings.windowAction(for: chord)
                if chord.modifiers.contains(.command) {
                    #expect(resolved == nil, "\(chord.display) must be left to the menu bar")
                } else {
                    #expect(resolved == entry.id, "\(chord.display) must reach the window")
                }
            }
        }
    }

    /// The bug this replaced: `⇧M`, `⌥M`, `⌥Space`, `⇧E` and `⌥3` all did
    /// something before, and none of them was written down anywhere.
    @Test("a modifier nothing binds is not a binding")
    func undocumentedModifierVariantsAreNotBound() {
        let unbound: [KeyChord] = [
            .key("m", .shift), .key("m", .option),
            KeyChord(.space, .option),
            .key("e", .shift), .key("r", .option),
            .key("3", .option), .key("3", .shift),
            .key("q", .option), .key("g", .option),
            KeyChord(.escape, .shift)
        ]
        for chord in unbound {
            #expect(
                KeyBindings.action(for: chord) == nil,
                "\(chord.display) resolves to \(KeyBindings.action(for: chord)?.rawValue ?? "")")
        }
    }

    /// macOS sets flags on an arrow key that nothing here binds, so an exact
    /// comparison against "bare ←" would never match without normalising first.
    /// This is the check that the arrows are reachable at all.
    @Test("an arrow press normalises past the modifiers macOS adds")
    func arrowPressesNormalise() {
        let bare = KeyChord.fromPress(
            character: KeyEquivalent.leftArrow.character, modifiers: [.numericPad, .capsLock])
        #expect(KeyBindings.windowAction(for: bare) == .nudgeBack)

        let shifted = KeyChord.fromPress(
            character: KeyEquivalent.rightArrow.character,
            modifiers: [.numericPad, .capsLock, .shift])
        #expect(KeyBindings.windowAction(for: shifted) == .selectionExtendRight)
    }

    /// Preserved from `DocumentView.handleLoop`, which recorded the reasoning:
    /// nothing in the app binds ⌃, and refusing a ⌃-modified press would make
    /// the plain actions unreachable for anyone whose hand rests on the key.
    @Test("⌃ is ignored rather than refused")
    func controlIsIgnored() {
        let chord = KeyChord.fromPress(character: "a", modifiers: [.control])
        #expect(KeyBindings.windowAction(for: chord) == .loopSetIn)
    }

    /// With ⌥ held, `press.characters` is the dead-key composition — "´" for ⌥E
    /// on a US layout — which is why the window reads `press.key.character`.
    /// A shifted letter arrives as its uppercase self and has to fold.
    @Test("a shifted letter folds to its own binding")
    func shiftedLettersFold() {
        #expect(KeyChord.fromPress(character: "W", modifiers: [.shift]) == .key("w", .shift))
        #expect(KeyBindings.windowAction(for: .key("w", .shift)) == .speedUpFine)
        let loopMove = KeyChord.fromPress(character: "A", modifiers: [.shift, .option])
        #expect(KeyBindings.windowAction(for: loopMove) == .loopMoveInLeftFar)
    }

    @Test("a chord displays the way a Mac user writes it")
    func chordsDisplayInAppleOrder() {
        #expect(KeyChord.key("i", [.option, .command]).display == "⌥⌘I")
        #expect(KeyChord.key("s", [.command, .shift]).display == "⇧⌘S")
        #expect(KeyChord(.space, .shift).display == "⇧Space")
        #expect(KeyChord.key("a", [.control, .option, .shift, .command]).display == "⌃⌥⇧⌘A")
    }
}
