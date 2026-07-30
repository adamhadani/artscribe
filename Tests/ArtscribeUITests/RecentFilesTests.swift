import Foundation
import Testing

@testable import ArtscribeUI

/// The Open Recent list: ordering, de-duplication, the cap, and persistence.
@MainActor
@Suite("Recent files")
struct RecentFilesTests {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private func makeStore() -> (RecentFiles, () -> Void) {
        let suite = "artscribe.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return (RecentFiles(), {})
        }
        return (
            RecentFiles(defaults: defaults), { defaults.removePersistentDomain(forName: suite) }
        )
    }

    // MARK: - The policy

    @Test("the most recently opened file comes first")
    func mostRecentFirst() {
        var list = RecentFiles.updated([], with: url("/a.wav"), limit: 5)
        list = RecentFiles.updated(list, with: url("/b.wav"), limit: 5)
        #expect(list.map(\.lastPathComponent) == ["b.wav", "a.wav"])
    }

    @Test("re-opening a file moves it up instead of duplicating it")
    func reopenMovesUp() {
        var list = [url("/a.wav"), url("/b.wav"), url("/c.wav")]
        list = RecentFiles.updated(list, with: url("/c.wav"), limit: 5)
        #expect(list.map(\.lastPathComponent) == ["c.wav", "a.wav", "b.wav"])
        #expect(list.count == 3)
    }

    /// `/tmp` is a symlink to `/private/tmp` on macOS, so the same file reached
    /// two ways would otherwise appear twice under one name — a menu with two
    /// identical-looking entries. Uses a file that really exists, because that
    /// is the only case in which the path can be resolved at all.
    @Test("the same file by a different path is not a second entry")
    func symlinkedPathsAreOneEntry() throws {
        let name = "artscribe-recents-\(UUID().uuidString).wav"
        let real = url("/private/tmp").appendingPathComponent(name)
        try Data().write(to: real)
        defer { try? FileManager.default.removeItem(at: real) }
        let viaSymlink = url("/tmp").appendingPathComponent(name)

        let list = RecentFiles.updated([viaSymlink], with: real, limit: 5)
        #expect(list.count == 1)
    }

    @Test("the list is capped and drops the oldest")
    func capped() {
        var list: [URL] = []
        for index in 0..<12 {
            list = RecentFiles.updated(list, with: url("/\(index).wav"), limit: 8)
        }
        #expect(list.count == 8)
        #expect(list.first?.lastPathComponent == "11.wav")
        #expect(list.last?.lastPathComponent == "4.wav")
    }

    @Test("a zero limit keeps nothing rather than trapping")
    func zeroLimit() {
        #expect(RecentFiles.updated([url("/a.wav")], with: url("/b.wav"), limit: 0).isEmpty)
    }

    // MARK: - Persistence

    @Test("the list survives a relaunch")
    func persists() {
        let suite = "artscribe.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not make a defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = RecentFiles(defaults: defaults)
        first.note(url("/music/one.flac"))
        first.note(url("/music/two.flac"))

        let second = RecentFiles(defaults: defaults)
        #expect(second.urls.map(\.lastPathComponent) == ["two.flac", "one.flac"])
    }

    @Test("clearing empties the list and the stored copy")
    func clearing() {
        let (store, cleanUp) = makeStore()
        defer { cleanUp() }
        store.note(url("/music/one.flac"))
        store.clear()
        #expect(store.urls.isEmpty)
    }

    @Test("a fresh install starts empty")
    func startsEmpty() {
        let (store, cleanUp) = makeStore()
        defer { cleanUp() }
        #expect(store.urls.isEmpty)
    }

    // MARK: - Security-scoped bookmarks (iPad)
    //
    // The bookmarks themselves cannot be exercised on macOS: `rememberBookmark`
    // is a deliberate no-op there, because this build is not sandboxed and a
    // path is sufficient. What *is* portable, and what these cover, is the
    // bookkeeping around them — the key both stores agree on, and the pruning
    // that stops the dictionary growing without bound. Resolution itself is
    // exercised on the simulator by the iOS run.

    /// Bookmarks and the recent list must agree on what "the same file" means,
    /// or a file reached through a symlink gets an entry that can never find its
    /// own bookmark.
    @Test("the bookmark key matches the de-duplication key")
    func bookmarkKeyMatchesDeduplication() {
        let direct = url("/tmp/track.wav")
        let awkward = url("/tmp/./track.wav")
        #expect(RecentFiles.key(for: direct) == RecentFiles.key(for: awkward))

        // And the list agrees: the awkward path is not a second entry.
        let list = RecentFiles.updated([direct], with: awkward, limit: 5)
        #expect(list.count == 1)
    }

    /// A missing bookmark must be a no-op, not a crash and not a substitution.
    /// This is the macOS path in full, and the iPad path whenever a file was
    /// added before bookmarks existed.
    @Test("resolving a file with no bookmark returns nil rather than guessing")
    func resolvingWithoutABookmark() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.note(url("/tmp/never-bookmarked.wav"))
        #expect(store.resolveBookmark(for: url("/tmp/never-bookmarked.wav")) == nil)
    }

    /// Clearing has to take the bookmarks with it. Leaving them behind would
    /// keep a record of files the user asked to forget.
    @Test("clearing forgets the bookmarks too")
    func clearingForgetsBookmarks() {
        let suite = "artscribe.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(["/tmp/a.wav": Data([1, 2, 3])], forKey: "recentFileBookmarks")
        let store = RecentFiles(defaults: defaults)
        store.clear()
        #expect(defaults.dictionary(forKey: "recentFileBookmarks") == nil)
    }

    /// The dictionary is otherwise append-only: every file ever opened would
    /// keep a bookmark forever, in a preferences file, for a menu showing eight.
    @Test("a bookmark is dropped once its file falls off the end of the list")
    func bookmarksArePruned() {
        let suite = "artscribe.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { defaults.removePersistentDomain(forName: suite) }

        let stale = "/tmp/stale.wav"
        defaults.set([stale: Data([1, 2, 3])], forKey: "recentFileBookmarks")
        let store = RecentFiles(defaults: defaults)

        // Push the list past its cap with other files; `stale` is never noted,
        // so it is not in the list and its bookmark has nothing to belong to.
        for i in 0..<(RecentFiles.limit + 2) { store.note(url("/tmp/f\(i).wav")) }

        let kept = defaults.dictionary(forKey: "recentFileBookmarks") as? [String: Data] ?? [:]
        #expect(kept[stale] == nil, "a bookmark outlived every reference to its file")
    }
}
