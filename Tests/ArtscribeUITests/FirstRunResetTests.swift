import Foundation
import Testing

@testable import ArtscribeUI

/// Putting a TestFlight build back to a new install, and — the half that
/// matters — never doing it anywhere else.
///
/// A released app that forgot a user's recents on every update would be a bug
/// report rather than a feature, so the environment check is not an
/// optimisation and both branches are asserted here. Neither can be exercised
/// on the machine this runs on, which is exactly why the detection is a pure
/// function of the receipt's *name*.
@Suite("First-run reset")
struct FirstRunResetTests {

    // MARK: - Which install is this

    @Test("the receipt's name says where the build came from")
    func environmentFromReceiptName() {
        #expect(InstallEnvironment.of(receiptName: nil) == .development)
        #expect(InstallEnvironment.of(receiptName: "sandboxReceipt") == .testFlight)
        #expect(InstallEnvironment.of(receiptName: "receipt") == .appStore)
    }

    /// Every documented location, and the `nil` that a `swift run` build gives.
    @Test("a receipt is found wherever the platform puts it")
    func receiptIsFoundOnEitherPlatform() {
        let bundle = URL(fileURLWithPath: "/tmp/Artscripture.app")
        for path in InstallEnvironment.receiptPaths {
            let planted = bundle.appending(path: path)
            let found = InstallEnvironment.receiptName(inBundleAt: bundle) { $0 == planted }
            #expect(found == (path as NSString).lastPathComponent, "not found at \(path)")
        }
        #expect(InstallEnvironment.receiptName(inBundleAt: bundle) { _ in false } == nil)
    }

    // MARK: - When to reset

    @Test("a TestFlight build resets when its build number moves")
    func testFlightResetsOnANewBuild() {
        #expect(FirstRunReset.shouldReset(environment: .testFlight, stored: "162", current: "163"))
    }

    /// Rolling back to compare two builds is still a change, and a tester doing
    /// it wants the same fresh start.
    @Test("going back to an earlier build counts as a change")
    func rollingBackAlsoResets() {
        #expect(FirstRunReset.shouldReset(environment: .testFlight, stored: "163", current: "162"))
    }

    @Test("relaunching the same build does not reset")
    func sameBuildDoesNothing() {
        #expect(!FirstRunReset.shouldReset(environment: .testFlight, stored: "163", current: "163"))
    }

    /// A container with no recorded build is a genuinely fresh install: there is
    /// nothing to put back, and the user is about to get the first run anyway.
    @Test("a fresh container is not a reset")
    func freshInstallDoesNothing() {
        #expect(!FirstRunReset.shouldReset(environment: .testFlight, stored: nil, current: "163"))
    }

    /// **The one that would be a bug report.** A shipped app must never do this,
    /// however far its build number has moved.
    @Test("the App Store never resets, whatever the build number does")
    func appStoreNeverResets() {
        for stored in ["1", "162", nil] {
            #expect(
                !FirstRunReset.shouldReset(environment: .appStore, stored: stored, current: "999"),
                "the App Store build reset with stored \(stored ?? "nil")")
        }
    }

    /// Nor a developer running locally, who would otherwise lose their recents
    /// on every rebuild.
    @Test("a development build never resets")
    func developmentNeverResets() {
        #expect(!FirstRunReset.shouldReset(environment: .development, stored: "1", current: "2"))
    }

    // MARK: - What a reset clears, and what it leaves

    @MainActor
    @Test("a reset takes back the welcome and the recents, and nothing else")
    func resetClearsFirstRunStateOnly() throws {
        let defaults = try #require(UserDefaults(suiteName: "reset-clears-\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let welcome = WelcomeState(defaults: defaults)
        welcome.markSeen()
        let recents = RecentFiles(defaults: defaults)
        recents.note(URL(fileURLWithPath: "/tmp/a.wav"))
        // A preference a tester deliberately set, which must survive.
        defaults.set(42, forKey: "someTesterPreference")

        FirstRunReset.reset(defaults: defaults, recents: recents)

        #expect(!WelcomeState(defaults: defaults).hasBeenSeen, "the tour was not offered again")
        #expect(recents.urls.isEmpty, "the recents survived, so the sample is still not offered")
        #expect(defaults.integer(forKey: "someTesterPreference") == 42, "a preference was lost")
    }

    @MainActor
    @Test("the build is recorded even when nothing was reset")
    func theBuildIsAlwaysRecorded() throws {
        let name = "reset-records-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let didReset = FirstRunReset.performIfNeeded(
            defaults: defaults, environment: .appStore, currentBuild: "163",
            recents: { RecentFiles(defaults: defaults) })

        #expect(!didReset)
        #expect(defaults.string(forKey: FirstRunReset.lastBuildKey) == "163")
    }

    /// The whole path, on the only environment that takes it.
    @MainActor
    @Test("a TestFlight update puts the first run back")
    func aTestFlightUpdateResets() throws {
        let name = "reset-testflight-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set("162", forKey: FirstRunReset.lastBuildKey)
        WelcomeState(defaults: defaults).markSeen()

        let didReset = FirstRunReset.performIfNeeded(
            defaults: defaults, environment: .testFlight, currentBuild: "163",
            recents: { RecentFiles(defaults: defaults) })

        #expect(didReset)
        #expect(!WelcomeState(defaults: defaults).hasBeenSeen)
        #expect(defaults.string(forKey: FirstRunReset.lastBuildKey) == "163")
    }
}
