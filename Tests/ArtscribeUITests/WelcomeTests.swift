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

    /// Brief, per the HIG. Four is a judgement, but an unbounded set is not —
    /// this fails loudly if someone adds a fifth without deciding to.
    @Test("there are four pages and none is empty")
    func pagesAreShortAndComplete() {
        #expect(WelcomePage.all.count == 4)
        for page in WelcomePage.all {
            #expect(!page.title.isEmpty, "page \(page.id) has no title")
            #expect(!page.body.isEmpty, "page \(page.id) has no body")
            #expect(!page.symbol.isEmpty, "page \(page.id) has no symbol")
        }
    }

    /// Every key the welcome names must be a real binding. The failure this
    /// catches is a page telling a first-time user to press something that does
    /// nothing — the worst possible moment for that.
    @Test("every key named on a page is really bound")
    func namedKeysExist() {
        let bound = Set(
            ActionCatalog.entries.flatMap { entry in
                entry.chords.map { $0.display }
            })
        for page in WelcomePage.all {
            for key in page.keys {
                #expect(bound.contains(key), "the welcome names \(key), which is not bound")
            }
        }
    }
}
