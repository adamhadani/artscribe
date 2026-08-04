import Foundation

/// How this copy of the app got onto the machine.
///
/// There is no Apple API that answers this, and there has never been one. What
/// every app uses instead is the **name of the receipt**: the App Store signs a
/// production build's receipt as `receipt`, and TestFlight re-signs the same
/// binary with a `sandboxReceipt`. A build that has no receipt at all was not
/// installed by either — it came from Xcode, from `swift run`, or from a
/// notarised download.
///
/// StoreKit 2's `AppTransaction.environment` is the modern answer to the
/// adjacent question and is deliberately not used here: it is `async`, it can
/// need the network on first call, and it exists to tell you where a *purchase*
/// came from. This decision has to be made synchronously before the first view
/// reads its defaults, and being wrong about it costs nothing worse than a tour
/// shown once too often.
public enum InstallEnvironment: String, CaseIterable, Sendable {
    /// A production build, from the App Store.
    case appStore
    /// A beta build, from TestFlight.
    case testFlight
    /// Xcode, `swift run`, or a notarised download — anything with no receipt.
    case development

    /// Named for the file the receipt is written as. Apple's, not ours.
    static let sandboxReceiptName = "sandboxReceipt"

    /// The pure half, so both branches are testable on a machine that is
    /// neither.
    public static func of(receiptName: String?) -> InstallEnvironment {
        switch receiptName {
        case nil: return .development
        case sandboxReceiptName: return .testFlight
        default: return .appStore
        }
    }

    /// Everywhere a receipt can be, on either platform.
    ///
    /// **The two roots are different containers, and getting that wrong is what
    /// made the first version of this file report `.development` on every
    /// TestFlight build.** On iOS the app bundle and the app's data live in
    /// sibling containers, and the receipt goes in the *data* one:
    ///
    /// ```
    /// bundle  …/Containers/Bundle/Application/<UUID>/Artscripture.app
    /// home    …/Containers/Data/Application/<UUID>            ← the receipt
    /// ```
    ///
    /// Measured on an iPad simulator running iOS 26.2, which is also where the
    /// second useful half of that came from: `NSHomeDirectory()` returns the
    /// data container root exactly, and the receipt sits at `StoreKit/receipt`
    /// relative to it. macOS is the other way round — there the receipt really
    /// is inside the bundle, at `Contents/_MASReceipt/`.
    ///
    /// Both roots are searched on both platforms rather than behind an `#if`.
    /// The paths do not collide, and a pure function over two explicit roots is
    /// checkable for every platform in one `make check` run.
    ///
    /// **Looked up on disk rather than through `Bundle.appStoreReceiptURL`**,
    /// which is deprecated in favour of StoreKit's `AppTransaction` — an API
    /// that answers a different question (where a *purchase* came from,
    /// asynchronously, possibly over the network) and has no bearing on this
    /// one. Marking a wrapper `@available(deprecated:)` to silence the warning
    /// propagates the deprecation to every caller, and `project.yml` sets
    /// `SWIFT_TREAT_WARNINGS_AS_ERRORS`, so the iPad target would not build.
    ///
    /// Sandbox first within each root; a sandbox receipt and a production one
    /// never coexist.
    static func receiptCandidates(bundle: URL, home: URL) -> [URL] {
        [
            home.appending(path: "StoreKit/sandboxReceipt"),
            home.appending(path: "StoreKit/receipt"),
            bundle.appending(path: "Contents/_MASReceipt/sandboxReceipt"),
            bundle.appending(path: "Contents/_MASReceipt/receipt")
        ]
    }

    /// The name of whichever receipt this install carries, or `nil` for one that
    /// carries none. `exists` is injected so every answer is testable on a
    /// machine that has neither.
    static func receiptName(bundle: URL, home: URL, exists: (URL) -> Bool) -> String? {
        receiptCandidates(bundle: bundle, home: home).first(where: exists)?.lastPathComponent
    }

    /// The variable that forces an answer, so the TestFlight path can be driven
    /// on a Mac or a simulator.
    ///
    /// This exists because the alternative is what happened: the reset shipped
    /// twice without the only branch that matters ever having run. An upload is
    /// a twelve-minute round trip and cannot be stepped through, so the branch
    /// has to be reachable somewhere cheaper. `ARTSCRIBE_DEV_MENU` is the same
    /// idea for the engine picker.
    ///
    /// Harmless in a shipped app: a sandboxed iOS app inherits no shell
    /// environment, so a build launched from the Home screen can never see it.
    static let overrideKey = "ARTSCRIBE_INSTALL_ENV"

    /// The override, if one is set and names a real case. A typo is `nil`
    /// rather than a default, so a misspelling behaves as no override at all
    /// instead of silently picking one.
    static func override(in environment: [String: String]) -> InstallEnvironment? {
        environment[overrideKey].flatMap(InstallEnvironment.init(rawValue:))
    }

    /// This build's.
    public static var current: InstallEnvironment {
        if let forced = override(in: ProcessInfo.processInfo.environment) { return forced }
        return of(
            receiptName: receiptName(
                bundle: Bundle.main.bundleURL,
                home: URL(fileURLWithPath: NSHomeDirectory())
            ) { FileManager.default.fileExists(atPath: $0.path) })
    }
}
