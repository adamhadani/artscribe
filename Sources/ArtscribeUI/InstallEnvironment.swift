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

    /// Where a receipt is written, relative to the app bundle, on each
    /// platform.
    ///
    /// **Looked up on disk rather than through `Bundle.appStoreReceiptURL`**,
    /// which is deprecated in favour of StoreKit's `AppTransaction` — an API
    /// that answers a different question (where a *purchase* came from,
    /// asynchronously, possibly over the network) and has no bearing on this
    /// one. Marking a wrapper `@available(deprecated:)` to silence the warning
    /// propagates the deprecation to every caller, which is worse than four
    /// path literals.
    ///
    /// The order matters only in that a sandbox receipt and a production one
    /// never coexist.
    static let receiptPaths = [
        "StoreKit/sandboxReceipt",
        "StoreKit/receipt",
        "Contents/_MASReceipt/sandboxReceipt",
        "Contents/_MASReceipt/receipt"
    ]

    /// The name of whichever receipt this bundle carries, or `nil` for a bundle
    /// that carries none. `exists` is injected so both answers are testable on
    /// a machine that has neither.
    static func receiptName(inBundleAt bundle: URL, exists: (URL) -> Bool) -> String? {
        for path in receiptPaths where exists(bundle.appending(path: path)) {
            return (path as NSString).lastPathComponent
        }
        return nil
    }

    /// This build's.
    public static var current: InstallEnvironment {
        of(
            receiptName: receiptName(inBundleAt: Bundle.main.bundleURL) {
                FileManager.default.fileExists(atPath: $0.path)
            })
    }
}
