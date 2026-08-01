import Foundation
import Observation

#if os(macOS)
import AppKit
#endif

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
/// The list itself is plain file URLs. Alongside it, and **only where one is
/// offered**, sits a security-scoped bookmark keyed by the same path.
///
/// That split is deliberate. On macOS this build is not sandboxed, a path is
/// enough, and no bookmark is ever recorded. On iPad a path is *not* enough: a
/// file picked out of Files — which is to say out of iCloud Drive, Dropbox or
/// anything else with a File Provider extension — lives outside the app's
/// container, and the URL the picker hands over stops being readable when the
/// app relaunches. Open Recent would list eight tracks and fail to open any of
/// them.
///
/// Bookmarks are stored under their own defaults key rather than by changing
/// how `urls` is written. Nothing has to migrate, an older build reading a newer
/// preferences file still finds its list, and the feature degrades to exactly
/// today's behaviour wherever a bookmark is missing or stale.
@MainActor
@Observable
public final class RecentFiles {
    /// How many to keep, and to show. macOS defaults to ten; a keyboard-first
    /// tool is better served by a list you can take in at a glance.
    public static let limit = 8

    private static let defaultsKey = "recentFiles"
    private static let bookmarksKey = "recentFileBookmarks"

    private let defaults: UserDefaults

    /// Most recent first.
    public private(set) var urls: [URL]

    /// Bookmark data by standardised path. Not `@Observable` state anyone reads
    /// — it changes nothing on screen — so it is kept out of the tracked
    /// surface, where it would invalidate the menu on every open.
    @ObservationIgnored private var bookmarks: [String: Data]

    /// - Parameter defaults: injectable so tests get their own suite instead of
    ///   writing into the user's real preferences.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        urls = Self.withoutStalePaths(
            (defaults.array(forKey: Self.defaultsKey) as? [String] ?? [])
                .map { URL(fileURLWithPath: $0) })
        bookmarks = defaults.dictionary(forKey: Self.bookmarksKey) as? [String: Data] ?? [:]
    }

    /// The key the bookmark store uses: **exactly the string `urls` is persisted
    /// as**, and nothing cleverer.
    ///
    /// This used to be `standardizedFileURL.resolvingSymlinksInPath().path`,
    /// borrowed from the de-duplication logic on the reasoning that two views of
    /// the same file should share a bookmark. That was wrong in a way only a
    /// device could show, and it broke Open Recent completely on iPad.
    ///
    /// **`resolvingSymlinksInPath()` touches the filesystem**, so its answer
    /// depends on whether the file is reachable *at that moment*. Minting a
    /// bookmark happens inside the document picker's completion, with access
    /// held; looking one up happens after a relaunch, with no access at all.
    /// Pulled off the device, the two stores disagreed exactly as that predicts:
    ///
    ///     recentFiles         /private/var/mobile/Library/CloudStorage/…
    ///     recentFileBookmarks         /var/mobile/Library/CloudStorage/…
    ///
    /// The bookmark was stored correctly every time. The lookup key simply never
    /// matched it, so every Open Recent fell back to the stale path and iOS
    /// refused with "you don't have permission to view it".
    ///
    /// Keying on `url.path` is correct **by construction** rather than by
    /// argument: `note` persists `urls.map(\.path)` and `init` rebuilds them
    /// with `URL(fileURLWithPath:)`, so this round-trips a listed entry to its
    /// own bookmark with no filesystem access and no cleverness in between.
    ///
    /// The cost is that the same file reached by two different paths keeps two
    /// bookmarks. That is a few hundred bytes, and it is the direction to be
    /// wrong in — de-duplication is `updated`'s job, and a bookmark that cannot
    /// be found is worth less than one stored twice.
    static func key(for url: URL) -> String {
        url.path
    }

    /// Records how to reach `url` again after the app is relaunched.
    ///
    /// **Must be called while security-scoped access to `url` is held**, which
    /// on iPad means inside the document picker's completion — a bookmark cannot
    /// be minted for a file the process is not currently allowed to read. That
    /// is also why this is separate from `note(_:)`: `note` runs when the decode
    /// *finishes*, by which time the picker's scope is long gone.
    ///
    /// Failure is not an error. A volume that does not support bookmarks, or a
    /// URL that has already lost its scope, simply leaves the entry as it is
    /// today — a path — and Open Recent behaves as it did before this existed.
    public func rememberBookmark(for url: URL) {
        #if os(macOS)
        // Not sandboxed: the path in `urls` is already sufficient, and minting
        // bookmarks would be storage nobody reads.
        _ = url
        #else
        guard let data = try? url.bookmarkData() else { return }
        bookmarks[Self.key(for: url)] = data
        defaults.set(bookmarks, forKey: Self.bookmarksKey)
        #endif
    }

    /// Resolves a remembered entry to a URL the app may actually read.
    ///
    /// Returns `nil` when there is nothing to resolve, which is the normal case
    /// on macOS and the graceful one everywhere: the caller falls back to the
    /// URL it already had.
    ///
    /// The returned URL has **already had `startAccessingSecurityScopedResource`
    /// called on it**, and the caller owns stopping it. `ViewerModel` is what
    /// does, because it is what knows when the file stops being read — see
    /// `open(url:securityScoped:)`.
    public func resolveBookmark(for url: URL) -> URL? {
        guard let data = bookmarks[Self.key(for: url)] else { return nil }
        var stale = false
        guard
            let resolved = try? URL(
                resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
            resolved.startAccessingSecurityScopedResource()
        else { return nil }
        // A stale bookmark still resolved, so the file is reachable — it has
        // just moved or been rewritten. Re-minting it now, while access is held,
        // is the one moment it can be done.
        if stale { rememberBookmark(for: resolved) }
        return resolved
    }

    /// Records a file that was opened successfully.
    public func note(_ url: URL) {
        urls = Self.updated(urls, with: url, limit: Self.limit)
        defaults.set(urls.map(\.path), forKey: Self.defaultsKey)
        pruneBookmarks()
        // Keeps the Dock menu and the system's own recents in step. Harmless
        // when it has nowhere to store them.
        //
        // macOS only, and not for want of an iOS equivalent to call: iOS has no
        // shared recent-documents list for an app to contribute to. The list
        // above *is* the feature on that platform, which is why it was never
        // left to `NSDocumentController` in the first place (see the type's own
        // comment).
        #if os(macOS)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        #endif
    }

    public func clear() {
        urls = []
        bookmarks = [:]
        defaults.removeObject(forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.bookmarksKey)
        #if os(macOS)
        NSDocumentController.shared.clearRecentDocuments(nil)
        #endif
    }

    /// Drops bookmarks for files that have fallen off the end of the list.
    ///
    /// Without this the dictionary is append-only: every file ever opened keeps
    /// a bookmark forever, in a preferences file, for a menu that shows eight.
    private func pruneBookmarks() {
        let live = Set(urls.map(Self.key(for:)))
        let kept = bookmarks.filter { live.contains($0.key) }
        guard kept.count != bookmarks.count else { return }
        bookmarks = kept
        defaults.set(bookmarks, forKey: Self.bookmarksKey)
    }

    /// The whole policy, as a pure function: most recent first, no duplicates,
    /// capped.
    ///
    /// Duplicates are compared by standardised path, so opening the same file
    /// through a symlink, a relative path or a `/private` prefix moves the
    /// existing entry to the top instead of adding a second one that looks
    /// identical in the menu.
    /// Drops entries that can never be opened again.
    ///
    /// An earlier build opened the bundled sample **in place**, so its recents
    /// entry contained the app bundle's UUID — which iOS regenerates on every
    /// install and update. Those entries fail with "the file could not be read"
    /// for ever. Filtering on read rather than migrating: there is nothing to
    /// migrate to, and the sample is one tap away on the resting screen.
    static func withoutStalePaths(_ urls: [URL]) -> [URL] {
        urls.filter { !SampleTrack.isStaleBundlePath($0) }
    }

    static func updated(_ existing: [URL], with url: URL, limit: Int) -> [URL] {
        guard limit > 0 else { return [] }
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        let kept = existing.filter {
            $0.standardizedFileURL.resolvingSymlinksInPath().path != key
        }
        return Array(([url] + kept).prefix(limit))
    }
}
