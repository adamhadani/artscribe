import Testing

@testable import ArtscribeUI

/// The gate on the developer submenu.
///
/// Tested through `isEnabled(in:)` rather than by setting a real environment
/// variable: the process environment is global, `swift test` runs concurrently,
/// and two tests mutating it would race. The pure function is the whole
/// decision; `isEnabled` is one `ProcessInfo` read in front of it.
@Suite("Developer menu gate")
struct DeveloperMenuTests {

    @Test("absent, empty or whitespace leaves it closed")
    func closedByDefault() {
        #expect(!DeveloperMenu.isEnabled(in: [:]))
        #expect(!DeveloperMenu.isEnabled(in: ["ARTSCRIBE_DEV_MENU": ""]))
        #expect(!DeveloperMenu.isEnabled(in: ["ARTSCRIBE_DEV_MENU": "   "]))
        #expect(!DeveloperMenu.isEnabled(in: ["SOMETHING_ELSE": "1"]))
    }

    /// The important half. A build that shipped with this open would put an
    /// engine picker — including Rubber Band R2, which drifts pitch by up to a
    /// semitone — in front of every user.
    @Test("only the documented off-values are off", arguments: ["0", "false", "no", "NO", "False"])
    func explicitlyOff(value: String) {
        #expect(!DeveloperMenu.isEnabled(in: ["ARTSCRIBE_DEV_MENU": value]))
    }

    /// Anything else means yes. Someone who typed `=yes` meant yes, and the cost
    /// of guessing wrong in this direction is a developer who does not get their
    /// menu — not a user who does.
    @Test("anything else opens it", arguments: ["1", "yes", "true", "on", "please"])
    func explicitlyOn(value: String) {
        #expect(DeveloperMenu.isEnabled(in: ["ARTSCRIBE_DEV_MENU": value]))
    }

    /// The key is part of the contract — it is in `README.md` and in the class
    /// doc comment, and renaming it would silently stop every documented
    /// invocation from working.
    @Test("the environment key is the documented one")
    func key() {
        #expect(DeveloperMenu.environmentKey == "ARTSCRIBE_DEV_MENU")
    }
}
