import AppKit
import Foundation

/// Writing a screenshot of the running window to disk.
///
/// Its own file because `AcceptanceInput` reached the project's 400-line limit,
/// and because this is the one part of the harness that touches the file system
/// — the rest of that file synthesises events and reads pixels back out of a
/// window.
extension AcceptanceRun {

    @MainActor
    static func snapshot(to path: String) {
        snapshot(NSApp.windows.first, to: path)
    }

    /// Captures one named window rather than the viewer. `cacheDisplay` draws
    /// the view itself, so this works with the login session's screen locked —
    /// a screen grab would not.
    @MainActor
    static func snapshot(_ window: NSWindow?, to path: String) {
        guard let window, let view = window.contentView,
            let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: path)
        // The directory has to exist first, and the write below is a `try?` that
        // would otherwise fail **silently** — the screenshots would simply not
        // be there, with the run still reporting success. That became a real
        // hazard the moment the default output stopped being the working
        // directory, which always exists.
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: url)
        } catch {
            // Not fatal — a missing screenshot is not a failed acceptance check
            // — but not silent either, per spec §8.
            FileHandle.standardError.write(
                Data("could not write \(path): \(error.localizedDescription)\n".utf8))
        }
    }
}
