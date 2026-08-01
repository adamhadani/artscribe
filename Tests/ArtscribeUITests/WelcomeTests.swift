import Foundation
import Testing

@testable import ArtscribeUI

/// The first-run welcome: when it appears, and that it stops.
///
/// The rules are Apple's, not invented here — the HIG asks that onboarding be
/// *optional*, that a skipped tutorial is *"not presented again on subsequent
/// launches"*, and that it stays *"easy to find later"*. The first two are
/// enforceable and are what these cover.
@Suite("Welcome sheet")
@MainActor
struct WelcomeTests {

    /// Its own defaults suite, so the run never reads or writes the real one —
    /// a test that marked the welcome seen in `.standard` would hide the sheet
    /// on the developer's own machine.
    private func scratchDefaults() throws -> UserDefaults {
        let name = "welcome-tests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    @Test("it appears on a first run and not afterwards")
    func appearsOnceOnly() throws {
        let defaults = try scratchDefaults()
        let first = WelcomeState(defaults: defaults)
        #expect(WelcomeState.shouldPresent(hasBeenSeen: first.hasBeenSeen))

        first.markSeen()

        // A *new* instance, as a relaunch would build: the decision has to
        // survive the process, not just the object.
        let relaunched = WelcomeState(defaults: defaults)
        #expect(!WelcomeState.shouldPresent(hasBeenSeen: relaunched.hasBeenSeen))
    }

    /// **Skipping counts as seen.** Apple draws no distinction between skipping
    /// and finishing, and re-asking someone who has decided is the behaviour the
    /// guidance forbids. `markSeen()` is what both buttons call.
    @Test("skipping is as final as finishing")
    func skippingCounts() throws {
        let defaults = try scratchDefaults()
        let state = WelcomeState(defaults: defaults)
        state.markSeen()
        #expect(WelcomeState(defaults: defaults).hasBeenSeen)
    }

    /// Replaying it from About must **not** clear the flag. If it did, the sheet
    /// would return unbidden on the next launch — the one thing the guidance
    /// rules out — for someone who had merely gone back to read it.
    @Test("replaying does not make it unseen")
    func replayLeavesItSeen() throws {
        let defaults = try scratchDefaults()
        let state = WelcomeState(defaults: defaults)
        state.markSeen()

        state.replayRequested = true

        #expect(state.hasBeenSeen)
        #expect(!WelcomeState.shouldPresent(hasBeenSeen: state.hasBeenSeen))
    }

    /// All three, every time. The tour is a pure function of the surface now, so
    /// the phone's reading is assertable from a Mac — which is the whole reason
    /// it is a function of the surface rather than an `#if`.
    private static let surfaces: [EmptyStatePrompt.Surface] = [
        .desktop, .tabletWithDrop, .phone
    ]

    /// Brief, per the HIG. Four is a judgement, but an unbounded set is not —
    /// this fails loudly if someone adds a fifth without deciding to.
    @Test("there are four pages and none is empty")
    func pagesAreShortAndComplete() {
        for surface in Self.surfaces {
            let pages = WelcomePage.pages(for: surface)
            #expect(pages.count == 4, "\(surface)")
            for page in pages {
                #expect(!page.title.isEmpty, "\(surface) page \(page.id) has no title")
                #expect(!page.body.isEmpty, "\(surface) page \(page.id) has no body")
                #expect(!page.symbol.isEmpty, "\(surface) page \(page.id) has no symbol")
            }
        }
    }

    /// Every key the welcome names must be a real binding — including the ones
    /// it reads off the transport buttons. The failure this catches is a page
    /// telling a first-time user to press something that does nothing, at the
    /// worst possible moment for that.
    @Test("every key named on a page is really bound")
    func namedKeysExist() {
        let bound = Set(
            ActionCatalog.entries.flatMap { entry in
                entry.chords.map { $0.display }
            })
        for surface in Self.surfaces {
            for page in WelcomePage.pages(for: surface) {
                let named = page.keys.map(\.key) + page.controls.map(\.shortcut)
                for key in named {
                    #expect(bound.contains(key), "the welcome names \(key), which is not bound")
                }
            }
        }
    }

    /// **Every key chip says what its key does.** A bare row of chips reading
    /// `1 2 3 4` shipped under a paragraph about pitch — they were the speed
    /// presets, not the pitch keys, and unlabelled they read as a page counter.
    @Test("every key chip is labelled with what it does")
    func keyChipsAreLabelled() {
        for surface in Self.surfaces {
            for page in WelcomePage.pages(for: surface) {
                for note in page.keys {
                    #expect(!note.label.isEmpty, "\(note.key) is shown with no label")
                    #expect(!note.key.isEmpty, "a chip labelled \(note.label) names no key")
                }
            }
        }
    }

    /// The tour's second page is a legend for the transport bar, so every button
    /// it explains has to still be *on* the bar. Removing a control without
    /// touching this file would leave the tour introducing a button that is not
    /// there — the icon would still resolve, so nothing else would notice.
    @Test("every button the tour explains is on the transport bar")
    func explainedControlsAreOnTheBar() {
        let onBar = Set(TransportControl.groups.flatMap { $0 })
        for surface in Self.surfaces {
            for page in WelcomePage.pages(for: surface) {
                for note in page.controls {
                    #expect(onBar.contains(note.control), "\(note.control) is not on the bar")
                    #expect(!note.meaning.isEmpty, "\(note.control) is introduced with no meaning")
                    #expect(!note.name.isEmpty, "\(note.control) has no name")
                    #expect(!note.symbol.isEmpty, "\(note.control) has no symbol")
                }
            }
        }
    }

    /// **The three buttons that carry someone from a drag to a repeating bar.**
    /// Selection → Loop exists because selecting used to dead-end, and a tour
    /// that does not name it leaves the dead end exactly where it was.
    @Test("the tour introduces the loop route on every surface")
    func loopRouteIsAlwaysTaught() {
        for surface in Self.surfaces {
            let introduced = Set(
                WelcomePage.pages(for: surface).flatMap { $0.controls.map(\.control) })
            for control in [TransportControl.loopFromSelection, .loop, .preroll] {
                #expect(introduced.contains(control), "\(surface) never introduces \(control)")
            }
        }
    }

    /// A phone gets no key chips anywhere — not in the standalone rows and not
    /// beside the buttons. It is the same rule the resting screen follows, and
    /// it is checked at the page level because that is where the omission would
    /// actually be made.
    @Test("a phone is never shown a key it cannot press")
    func phonesSeeNoKeys() {
        #expect(!WelcomePage.showsKeys(on: .phone))
        #expect(WelcomePage.showsKeys(on: .desktop))
        #expect(WelcomePage.showsKeys(on: .tabletWithDrop))
        for page in WelcomePage.pages(for: .phone) {
            #expect(page.keys.isEmpty, "page \(page.id) offers keys to a phone")
        }
    }

    /// Practice and the shortcut reference are the two things most likely to go
    /// unfound, and on a touch device the ⋯ menu is the only route to either —
    /// so the last page has to point at whichever route the device has.
    @Test("the last page says where the panels live")
    func lastPageNamesThePanels() {
        for surface in Self.surfaces {
            let last = WelcomePage.pages(for: surface)[3]
            #expect(last.body.contains("Practice"), "\(surface): \(last.body)")
            #expect(last.body.contains("shortcut reference"), "\(surface): \(last.body)")
            switch surface {
            case .desktop: #expect(last.body.contains("Playback menu"))
            case .tabletWithDrop, .phone: #expect(last.body.contains("⋯"))
            }
        }
    }
}
