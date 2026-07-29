import Testing

@testable import ArtscribeUI

/// The shortcut window's focus rules, as the two questions they actually are.
///
/// The view half — that a click on the drawn keyboard really does reach
/// `ShortcutFocusMonitor`, and that `makeFirstResponder(nil)` really does take
/// the field editor out of the responder chain — is measured in the acceptance
/// run, where there is a window. What is here is the policy those measurements
/// exercise, stated so that changing it has to be deliberate.
@Suite("The shortcut window's filter focus")
struct FilterFocusTests {

    // MARK: - Escape

    @Test("Esc over a filter with text in it clears the text and keeps the caret")
    func escapeClearsBeforeItLeaves() {
        #expect(FilterFocus.escape(isFocused: true, text: "loop") == .clearTheFilter)
    }

    @Test("Esc over an empty filter gives the keyboard back")
    func escapeReleasesAnEmptyFilter() {
        #expect(FilterFocus.escape(isFocused: true, text: "") == .releaseTheKeyboard)
    }

    /// The half that stops this from swallowing `⎋` app-wide. The Edit menu
    /// binds `⎋` to Clear Selection, and a monitor that answered it whether or
    /// not the filter was focused would take that key away from the document
    /// window — one defect traded for another.
    @Test("Esc with nothing focused is not ours")
    func escapeWithNothingFocusedPassesThrough() {
        #expect(FilterFocus.escape(isFocused: false, text: "") == .passItOn)
        #expect(FilterFocus.escape(isFocused: false, text: "loop") == .passItOn)
    }

    /// A single space is text. The clear step keys off emptiness, not off
    /// whitespace, because a filter holding " " is narrowing the list to
    /// nothing and the reader has to be able to undo that before leaving.
    @Test("whitespace counts as text")
    func whitespaceIsText() {
        #expect(FilterFocus.escape(isFocused: true, text: " ") == .clearTheFilter)
    }

    // MARK: - Clicks

    @Test("a click outside the field takes the keyboard off it")
    func clickOutsideReleases() {
        #expect(FilterFocus.click(isFocused: true, insideField: false) == .releaseTheKeyboard)
    }

    @Test("a click on the field leaves it alone")
    func clickInsideKeepsFocus() {
        #expect(FilterFocus.click(isFocused: true, insideField: true) == .passItOn)
    }

    /// The common case by a wide margin — this window is read far more often
    /// than it is typed into — and the one that must cost nothing: with no
    /// field editor there is no focus to release, so every click in the window
    /// goes straight through to the divider, the picker and the list.
    @Test("a click with nothing focused is not ours either")
    func clickWithNothingFocusedPassesThrough() {
        #expect(FilterFocus.click(isFocused: false, insideField: false) == .passItOn)
        #expect(FilterFocus.click(isFocused: false, insideField: true) == .passItOn)
    }

    /// Stated as a pair rather than as two independent rules: focus is a
    /// **two-way** state, and the defect this replaces was one that could only
    /// be entered. Every focused input has an exit.
    @Test("every way in has a way out")
    func focusIsTwoWay() {
        let waysOut: [FilterFocus.Action] = [
            FilterFocus.escape(isFocused: true, text: ""),
            FilterFocus.click(isFocused: true, insideField: false)
        ]
        #expect(waysOut.allSatisfy { $0 == .releaseTheKeyboard })
    }
}
