import AppKit
import Foundation
import Observation

/// The **Open Recent** list.
///
/// Kept here rather than left entirely to `NSDocumentController` because this is
/// not an `NSDocument` app: nothing calls `noteNewRecentDocumentURL` for us, and
/// an unbundled SwiftPM build has no bundle identifier for the system list to
/// key on, so relying on it alone would give a menu that is silently always
/// empty. The system is told as well — that is what puts the same files in the
/// Dock menu once the app is bundled (Task 12) — but the menu is drawn from
/// this, which is storage this app controls and can test.
///
/// Plain file URLs, not security-scoped bookmarks: this build is not sandboxed.
/// A sandboxed build would have to store bookmark data instead, and that is a
/// change here rather than at the call sites.
@MainActor
@Observable
public final class RecentFiles {
    /// How many to keep, and to show. macOS defaults to ten; a keyboard-first
    /// tool is better served by a list you can take in at a glance.
    public static let limit = 8

    private static let defaultsKey = "recentFiles"

    private let defaults: UserDefaults

    /// Most recent first.
    public private(set) var urls: [URL]

    /// - Parameter defaults: injectable so tests get their own suite instead of
    ///   writing into the user's real preferences.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        urls = (defaults.array(forKey: Self.defaultsKey) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }
    }

    /// Records a file that was opened successfully.
    public func note(_ url: URL) {
        urls = Self.updated(urls, with: url, limit: Self.limit)
        defaults.set(urls.map(\.path), forKey: Self.defaultsKey)
        // Keeps the Dock menu and the system's own recents in step. Harmless
        // when it has nowhere to store them.
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    public func clear() {
        urls = []
        defaults.removeObject(forKey: Self.defaultsKey)
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    /// The whole policy, as a pure function: most recent first, no duplicates,
    /// capped.
    ///
    /// Duplicates are compared by standardised path, so opening the same file
    /// through a symlink, a relative path or a `/private` prefix moves the
    /// existing entry to the top instead of adding a second one that looks
    /// identical in the menu.
    static func updated(_ existing: [URL], with url: URL, limit: Int) -> [URL] {
        guard limit > 0 else { return [] }
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        let kept = existing.filter {
            $0.standardizedFileURL.resolvingSymlinksInPath().path != key
        }
        return Array(([url] + kept).prefix(limit))
    }
}
