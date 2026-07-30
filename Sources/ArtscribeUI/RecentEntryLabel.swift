import Foundation

/// How a recent file describes itself in a list.
///
/// Pure, and separate from the view, because the interesting part is not the
/// layout: it is that `02 - woody 'n' you.mp3` is a useless label on its own when
/// half an album is in the list. The name answers *which track*; the folder
/// answers *which of the four copies of it you have*.
enum RecentEntryLabel {

    /// The file name, extension included.
    ///
    /// The extension stays. This is a tool where FLAC and MP3 of the same track
    /// are meaningfully different files, and stripping it would make them
    /// indistinguishable in exactly the list meant to tell them apart.
    static func name(for url: URL) -> String {
        url.lastPathComponent
    }

    /// The containing folder, or `nil` when there is nothing useful to say.
    ///
    /// Just the immediate parent, not the path. A full path is unreadable at a
    /// glance and, on iOS, is a container UUID nobody recognises — the folder an
    /// album lives in is the piece a person actually navigates by.
    ///
    /// `nil` rather than `"/"` for a file at the root, and `nil` when the parent
    /// would only repeat the file name, so the view can omit the line instead of
    /// drawing something that says nothing.
    static func folder(for url: URL) -> String? {
        let parent = url.deletingLastPathComponent().lastPathComponent
        guard !parent.isEmpty, parent != "/", parent != url.lastPathComponent else {
            return nil
        }
        return parent
    }
}
