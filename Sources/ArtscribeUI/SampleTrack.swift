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

    /// The 28-second excerpt as it ships, inside the app's resource bundle.
    ///
    /// **Not what gets opened.** See `installedURL()`: this path lives under
    /// `…/Bundle/Application/<UUID>/Artscripture.app/…`, and iOS regenerates
    /// that UUID on every install and every TestFlight update.
    ///
    /// `nil` would mean the resource did not make it into the bundle. The caller
    /// hides the offer rather than showing a button that cannot work — a missing
    /// file is a build fault, and the user is not the right person to tell.
    static var bundledURL: URL? {
        Bundle.module.url(forResource: "GoldbergVariatio4", withExtension: "m4a")
    }

    /// Where the sample is opened *from*: a real file in the app's Documents
    /// folder, copied out of the bundle the first time it is wanted.
    ///
    /// ## Why it cannot be opened in place
    ///
    /// Opening the bundled copy worked, and then broke in two ways that both
    /// looked like something else:
    ///
    ///  * **Recents stopped working.** The stored path contains the app bundle's
    ///    UUID, which iOS regenerates on every install and update — so after the
    ///    next TestFlight build the entry pointed into a bundle that no longer
    ///    existed and the user got "the file could not be read". Reported.
    ///  * **Its sidecar could never sit beside it.** An app bundle is read-only,
    ///    so saving a session for the sample always fell back to Application
    ///    Support and raised the banner that says so — for a file the user had
    ///    done nothing unusual with.
    ///
    /// Documents rather than Application Support, deliberately: the app sets
    /// `UIFileSharingEnabled`, so the sample and its `.artscripture` sidecar are
    /// both visible in Files. That matches what this project says about session
    /// files being things you can see, read and delete.
    ///
    /// Returns the bundled URL as a fallback if the copy fails, which keeps the
    /// first run working even on a full disk — that path is still readable, it
    /// simply will not survive an update.
    static func installedURL(
        in directory: FileManager.SearchPathDirectory = .documentDirectory
    ) -> URL? {
        guard let bundled = bundledURL else { return nil }
        let manager = FileManager.default
        guard let root = manager.urls(for: directory, in: .userDomainMask).first else {
            return bundled
        }
        let destination = root.appendingPathComponent(bundled.lastPathComponent)
        if manager.fileExists(atPath: destination.path) { return destination }
        do {
            try manager.copyItem(at: bundled, to: destination)
            return destination
        } catch {
            // Readable, just not durable. Better than refusing to open the one
            // thing an empty app offers.
            return bundled
        }
    }

    /// A recents entry that can never be opened again.
    ///
    /// Anything under `…/Bundle/Application/…` belonged to a previous install of
    /// this or another app. Entries like that were written by the version that
    /// opened the sample in place, and they fail with "the file could not be
    /// read" every time — so they are dropped rather than left to disappoint.
    static func isStaleBundlePath(_ url: URL) -> Bool {
        url.path.contains("/Bundle/Application/")
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
