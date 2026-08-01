/// Whether the document still owns the menu's plain-letter key equivalents.
///
/// The iPad counterpart to `KeyWindowTracker`, which answers the same question
/// on macOS by asking AppKit which window is key. iPad has one window, so the
/// question is asked of the **sheets** instead.
///
/// ## The bug it exists for
///
/// The menu carries plain-letter equivalents — `1`–`4` for speed, `A`–`G` for
/// the loop, `Q`/`W`, Space. They are offered the keystroke *before* a focused
/// text field is. With Settings open, typing `1` into a nudge field therefore
/// set the speed to 100% and entered nothing, and almost every digit and letter
/// is bound, so numeric entry was impossible. Reported from TestFlight.
///
/// `ActionMenuItem` had predicted it in a comment — *"a presented sheet does
/// take the keyboard, so this should eventually consult the sheet state … until
/// the sheets exist there is nothing to consult"* — and the sheets then arrived.
///
/// ## Why it is a free function over `Bool`s
///
/// So it runs in `make check`. `AuxiliaryWindow` has two implementations and the
/// sheet half (`isPresented`) exists only on iOS, so a test written against the
/// live objects would compile out of the macOS suite and would not run in
/// `make ios-test` either — `ArtscribeUITests` is not in the portable bundle. A
/// test that never executes is worse than none, so the decision is separated
/// from the state it reads, which is this project's usual answer for views.
enum SheetFocus {

    /// `true` when no auxiliary surface is presented, and the document should
    /// keep claiming plain-letter key equivalents.
    ///
    /// **All four surfaces count**, including About, which has no text fields.
    /// A sheet over the document is the keyboard's target whether or not it
    /// wants characters, and a uniform rule is one fewer thing to get wrong when
    /// the next sheet is added.
    static func documentHasKeyboard(
        shortcutsPresented: Bool,
        practicePresented: Bool,
        aboutPresented: Bool,
        settingsPresented: Bool
    ) -> Bool {
        !(shortcutsPresented || practicePresented || aboutPresented || settingsPresented)
    }
}
