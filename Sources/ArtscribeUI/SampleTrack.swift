import Foundation

/// The track that ships inside the app, and the rule for when to offer it.
///
/// ## Why it exists at all
///
/// App Store guideline 2.1 rejects incomplete bundles, and this app needs a file
/// the user supplies before it can do anything. A reviewer opens it on a device
/// with no music on it, meets a drop target, and has no way to see the product
/// work — which is the single most likely way a transcription tool gets turned
/// down. A bundled excerpt answers that in the one way a description cannot.
///
/// ## Why it is only ever a first-run offer
///
/// It is scaffolding for an empty app, not a feature. The moment there is a
/// recent file, the resting screen has something better to show — the track the
/// user was actually working on — and a permanent "try the demo" button would
/// sit there implying the app is still a demo. So `isOffered` is a function of
/// the recents being empty, and nothing else.
///
/// That also makes it honest about state rather than about time: someone who
/// clears their recents is back to an empty app and gets the offer again, which
/// is right, and someone who opens their own track never sees it twice.
enum SampleTrack {

    /// What the recents list is shown as, and what the About panel credits.
    static let title = "Bach — Goldberg Variations, Variatio 4"

    /// The performer, and the reason this file may ship in a paid binary.
    ///
    /// Kimiko Ishizaka's *Open Goldberg Variations* was crowd-funded expressly
    /// to place the recording in the public domain, and archive.org carries
    /// `licenseurl = creativecommons.org/publicdomain/zero/1.0/` on the item —
    /// CC0 by the project's intent, not by an assumption that old music is free.
    /// The performance is 2012; only the *composition* is old, and a recording
    /// carries its own copyright, which is exactly the trap this avoids.
    static let credit = "Kimiko Ishizaka — The Open Goldberg Variations (CC0)"

    static let source = "https://archive.org/details/The_Open_Goldberg_Variations-11823"

    /// A 28-second excerpt, in the app's own resource bundle.
    ///
    /// `nil` would mean the resource did not make it into the bundle. The caller
    /// hides the offer rather than showing a button that cannot work — a missing
    /// file is a build fault, and the user is not the right person to tell.
    static var url: URL? {
        Bundle.module.url(forResource: "GoldbergVariatio4", withExtension: "m4a")
    }

    /// Whether to offer the sample, given how many recent files there are.
    ///
    /// Pure, and takes the count rather than reading `RecentFiles` itself, so
    /// the rule is testable without a `UserDefaults` round trip — and so that
    /// the view cannot accidentally consult a different source of truth than the
    /// one the list is drawn from.
    static func isOffered(recentCount: Int) -> Bool {
        recentCount == 0
    }
}
