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
        let bundle = URL(fileURLWithPath: "/tmp/Bundle/Artscripture.app")
        let home = URL(fileURLWithPath: "/tmp/Data")
        for planted in InstallEnvironment.receiptCandidates(bundle: bundle, home: home) {
            let found = InstallEnvironment.receiptName(bundle: bundle, home: home) { $0 == planted }
            #expect(
                found == planted.lastPathComponent, "not found at \(planted.path)")
        }
        let none = InstallEnvironment.receiptName(bundle: bundle, home: home) { _ in false }
        #expect(none == nil)
    }

    /// **The defect that made this feature dead on arrival.**
    ///
    /// On iOS the receipt is not in the app bundle — it is in the *data*
    /// container, a sibling root (`…/Containers/Data/Application/<UUID>/`,
    /// which is what `NSHomeDirectory()` returns) rather than
    /// `…/Containers/Bundle/Application/<UUID>/Artscripture.app`. Probing only
    /// under the bundle finds nothing on a real TestFlight install, every build
    /// calls itself `.development`, and the reset can never fire.
    ///
    /// Measured on an iPad simulator running iOS 26.2:
    ///
    /// ```
    /// bundleURL  = …/Containers/Bundle/Application/<UUID>/Artscripture.app
    /// receiptURL = …/Containers/Data/Application/<UUID>/StoreKit/receipt
    /// ```
    @Test("a TestFlight receipt in the data container is found")
    func receiptIsFoundInTheDataContainer() {
        let bundle = URL(fileURLWithPath: "/tmp/Containers/Bundle/App/Artscripture.app")
        let home = URL(fileURLWithPath: "/tmp/Containers/Data/App")
        let planted = home.appending(path: "StoreKit/sandboxReceipt")

        let found = InstallEnvironment.receiptName(bundle: bundle, home: home) { $0 == planted }

        #expect(found == "sandboxReceipt", "the receipt was not found outside the bundle")
        #expect(InstallEnvironment.of(receiptName: found) == .testFlight)
    }

    /// The override that makes every branch reachable on a Mac, which is the
    /// only reason any of this could be checked before an upload.
    @Test("the environment can be overridden for local testing")
    func environmentOverride() {
        let key = InstallEnvironment.overrideKey
        #expect(InstallEnvironment.override(in: [key: "testFlight"]) == .testFlight)
        #expect(InstallEnvironment.override(in: [key: "appStore"]) == .appStore)
        #expect(InstallEnvironment.override(in: [:]) == nil, "an unset variable must not override")
        let typo = InstallEnvironment.override(in: [key: "nonsense"])
        #expect(typo == nil, "a typo must not override")
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

    /// **The other half of why build 164 showed nobody the tour.**
    ///
    /// `nil` was read as "a genuinely fresh install, nothing to put back". It is
    /// not: 164 was the first build to *write* `lastRunBuildVersion`, so every
    /// existing tester's container had `nil` alongside a welcome flag and a full
    /// recents list. The one case the transition had to cover was the one it
    /// excluded.
    ///
    /// Treating `nil` as a change is right in both directions, because on a
    /// container that really is fresh the reset clears a flag that is already
    /// false and a list that is already empty.
    @Test("a container from before this feature existed still resets")
    func aContainerPredatingTheFeatureResets() {
        #expect(FirstRunReset.shouldReset(environment: .testFlight, stored: nil, current: "165"))
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

    /// **The manual reset has to act on the live objects, and be visible now.**
    ///
    /// `WelcomeState` reads its flag once in `init`, so a reset routed through a
    /// fresh instance would write to `UserDefaults` and leave the object the
    /// sheet is bound to still saying "seen" — a reset that works perfectly and
    /// appears to do nothing until the next launch. And `DocumentView` only
    /// samples `hasBeenSeen` in `onAppear`; `replayRequested` is the one trigger
    /// it watches while already on screen.
    @MainActor
    @Test("a manual reset clears the live state and asks for the tour now")
    func manualResetActsOnTheLiveObjects() throws {
        let name = "reset-live-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let welcome = WelcomeState(defaults: defaults)
        welcome.markSeen()
        let recents = RecentFiles(defaults: defaults)
        recents.note(URL(fileURLWithPath: "/tmp/a.wav"))

        FirstRunReset.reset(welcome: welcome, recents: recents)

        #expect(!welcome.hasBeenSeen, "the live object still says the tour has been seen")
        #expect(recents.urls.isEmpty)
        #expect(welcome.replayRequested, "the tour would not appear until the next launch")
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
