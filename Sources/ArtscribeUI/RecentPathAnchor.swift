import Foundation

/// Re-anchoring a remembered path onto the container the app is running in now.
///
/// ## The bug this exists for, twice
///
/// iOS gives an app two containers, and **the absolute path of each contains a
/// UUID that the system is free to change**:
///
///     …/Containers/Bundle/Application/<UUID>/Artscripture.app/…   the bundle
///     …/Containers/Data/Application/<UUID>/Documents/…            everything else
///
/// The sample track was first opened in place, from the *bundle* — so its
/// recents entry died on the next TestFlight build. That was fixed by copying it
/// to Documents, which fixed the symptom and moved the cause: `Documents` is in
/// the **data** container, whose UUID moves for exactly the same reasons. The
/// same report came back after the next update.
///
/// Measured rather than assumed: reinstalling on a simulator took the data
/// container from `F465616D-…` to `312E214E-…` while `recentFiles` still held
/// the old one. iOS migrates the *contents* across, so the preferences survive
/// intact and every absolute path inside them is dead — which is why this fails
/// while looking like the file was deleted.
///
/// ## What this does about it
///
/// Nothing on load unless a path is actually broken. A remembered file that
/// still opens is left exactly as it is, so a file in *another* app's container,
/// or on a volume that merely happens to be laid out this way, is never
/// rewritten out from under itself. Only when the stored path cannot be read
/// **and** the re-anchored one can is the entry healed — and then it is written
/// back, so it heals once rather than on every launch.
///
/// Pure, and takes the home directory as an argument, so all of it is testable
/// on a Mac — where `NSHomeDirectory()` is `/Users/…`, the marker never matches,
/// and every one of these functions is correctly a no-op.
enum RecentPathAnchor {

    /// The one substring every iOS data-container path contains, and no macOS
    /// path does. Matching on this rather than on the home directory's own
    /// prefix is what lets an *old* container be recognised: the whole point is
    /// that its prefix is not the current one.
    static let containerMarker = "/Containers/Data/Application/"

    /// `path` as it would be inside the container rooted at `home`, or `nil`
    /// when `path` does not look like a container path at all.
    ///
    /// The UUID component immediately after the marker is what gets replaced —
    /// everything before it belongs to the device or the simulator, and
    /// everything after it is the app's own layout, which does not change.
    static func reanchored(_ path: String, home: String) -> String? {
        guard let markerEnd = path.range(of: containerMarker)?.upperBound else { return nil }
        let afterMarker = path[markerEnd...]
        // Drop the UUID component. `dropFirst` on the split rather than an index
        // search, so a path that is *only* the container root yields nil rather
        // than the home directory itself.
        let components = afterMarker.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count > 1 else { return nil }
        let relative = components.dropFirst().joined(separator: "/")
        guard !relative.isEmpty else { return nil }
        return home + "/" + relative
    }

    /// The URL to remember for `url`: itself when it still opens, and the
    /// re-anchored one when *that* is what exists instead.
    ///
    /// **It never drops an entry**, which is the important half. "Does not exist"
    /// is not the same as "is gone": a file in iCloud Drive that has not been
    /// downloaded, one on an unmounted volume, and one reachable only through a
    /// security-scoped bookmark all fail `fileExists` while being perfectly
    /// openable a moment later. So an unrecognised path is returned untouched
    /// and the existing bookmark path gets its chance.
    ///
    /// `exists` is injected so the decision is testable without laying out two
    /// fake containers on disk — and because the real one is a filesystem call
    /// this type has no business making on its own.
    static func healed(_ url: URL, home: String, exists: (String) -> Bool) -> URL {
        guard !exists(url.path),
            let candidate = reanchored(url.path, home: home),
            exists(candidate)
        else { return url }
        return URL(fileURLWithPath: candidate)
    }
}
