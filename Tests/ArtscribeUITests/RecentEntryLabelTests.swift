import Foundation
import Testing

@testable import ArtscribeUI

/// How a recent file names itself on the resting screen.
@Suite("Recent entry labels")
struct RecentEntryLabelTests {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    /// The extension stays. FLAC and MP3 of the same track are meaningfully
    /// different files here, and stripping it would make them indistinguishable
    /// in the list whose job is telling them apart.
    @Test("the name keeps its extension")
    func nameKeepsExtension() {
        #expect(RecentEntryLabel.name(for: url("/music/Diz/02 - woody.mp3")) == "02 - woody.mp3")
        #expect(RecentEntryLabel.name(for: url("/music/Diz/02 - woody.flac")) == "02 - woody.flac")
    }

    /// The immediate folder, not the path — which is what a person navigates by,
    /// and on iOS the path is a container UUID nobody recognises.
    @Test("the folder is the immediate parent")
    func folderIsImmediateParent() {
        #expect(RecentEntryLabel.folder(for: url("/music/Jazz/Diz/02.mp3")) == "Diz")
    }

    /// Nothing useful to say beats saying something useless: the view omits the
    /// second line entirely rather than drawing "/" under a file's name.
    @Test("a file with no meaningful parent has no folder line")
    func noFolderWhenThereIsNothingToSay() {
        #expect(RecentEntryLabel.folder(for: url("/track.mp3")) == nil)
    }

    /// Both halves must survive the paths this app actually sees: the `/private`
    /// container URLs from an iPad's document picker, and names with spaces,
    /// apostrophes and dots in them.
    @Test("awkward real-world paths still label sensibly")
    func awkwardPaths() {
        let picked = url(
            "/private/var/mobile/Library/CloudStorage/Reference Music/Gonzalo Rubalcaba - Diz/"
                + "02 - woody 'n' you.mp3")
        #expect(RecentEntryLabel.name(for: picked) == "02 - woody 'n' you.mp3")
        #expect(RecentEntryLabel.folder(for: picked) == "Gonzalo Rubalcaba - Diz")
    }
}
