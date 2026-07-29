import ArtscribeKit
import Foundation
import Testing

@testable import ArtscribeUI

/// Finding the right cue sheet, and reading it whatever it is encoded in.
///
/// The reference corpus is entirely US-ASCII, so it exercises none of the
/// encoding fallbacks — these fixtures are what cover them, and they are
/// synthetic on purpose rather than a file checked in beside the tests.
@MainActor
@Suite("Cue sheet loading")
struct CueSheetLoaderTests {

    /// A throwaway directory, removed when the test ends.
    private struct Scratch: ~Copyable {
        let url: URL
        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("cue-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        func write(_ name: String, _ contents: String) throws -> URL {
            let file = url.appendingPathComponent(name)
            try contents.write(to: file, atomically: true, encoding: .utf8)
            return file
        }
        func touch(_ name: String) throws -> URL { try write(name, "") }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private static let sheet = """
        FILE "whatever.wav" WAVE
          TRACK 01 AUDIO
            TITLE "One"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Two"
            INDEX 01 01:00:00
        """

    // MARK: - Which sheet

    /// The corpus has `Suite 4 y 20.cue` and `Suite 4 y 20.ape.cue` side by
    /// side, and `XXI Century.FLAC.cue` beside `XXI Century.WAV.cue`. Whichever
    /// the directory happens to list first is not an answer: it has to be the
    /// same on every machine and every launch.
    @Test("the sheet naming this audio's own format wins over the plain one")
    func formatSpecificSheetWins() throws {
        let scratch = try Scratch()
        _ = try scratch.write("Album.cue", Self.sheet)
        _ = try scratch.write("Album.flac.cue", Self.sheet)
        _ = try scratch.write("Album.wav.cue", Self.sheet)
        let audio = try scratch.touch("Album.flac")
        let best = try #require(CueSheetLoader.candidates(besides: audio).first)
        #expect(best.lastPathComponent == "Album.flac.cue")
    }

    @Test("failing that, the plain sibling")
    func plainSiblingIsNext() throws {
        let scratch = try Scratch()
        _ = try scratch.write("Album.cue", Self.sheet)
        let audio = try scratch.touch("Album.flac")
        #expect(CueSheetLoader.candidates(besides: audio).first?.lastPathComponent == "Album.cue")
    }

    /// `Gonzalo Rubalcaba.CUE` is real, and so is the habit of naming the sheet
    /// after the album while the audio carries a track number.
    @Test("the extension is matched case-insensitively")
    func upperCaseExtension() throws {
        let scratch = try Scratch()
        _ = try scratch.write("Album.CUE", Self.sheet)
        let audio = try scratch.touch("Album.flac")
        #expect(CueSheetLoader.candidates(besides: audio).first?.lastPathComponent == "Album.CUE")
    }

    @Test("a lone differently-named sheet is still taken")
    func loneSheet() throws {
        let scratch = try Scratch()
        _ = try scratch.write("The Album Name.cue", Self.sheet)
        let audio = try scratch.touch("01 - Track.flac")
        #expect(CueSheetLoader.candidates(besides: audio).count == 1)
    }

    /// But only when it is unambiguous. Two unrelated sheets and no name match
    /// is a guess, and a wrong cue sheet puts markers in confidently wrong
    /// places — worse than none, which is the whole spec §8 principle.
    @Test("two unrelated sheets are ambiguous, so neither is guessed at")
    func ambiguousSheetsAreDeclined() throws {
        let scratch = try Scratch()
        _ = try scratch.write("Disc One.cue", Self.sheet)
        _ = try scratch.write("Disc Two.cue", Self.sheet)
        let audio = try scratch.touch("01 - Track.flac")
        #expect(CueSheetLoader.candidates(besides: audio).isEmpty)
    }

    @Test("no sheet at all is not an error")
    func noSheet() throws {
        let scratch = try Scratch()
        let audio = try scratch.touch("Album.flac")
        #expect(CueSheetLoader.candidates(besides: audio).isEmpty)
        #expect(CueSheetLoader.load(besides: audio, sampleRate: 44100) == .none)
    }

    // MARK: - End to end

    @Test("a sibling sheet is found, parsed, and its markers converted")
    func loadsAndParses() throws {
        let scratch = try Scratch()
        _ = try scratch.write("Album.cue", Self.sheet)
        let audio = try scratch.touch("Album.flac")
        guard
            case .loaded(let parsed, let from) = CueSheetLoader.load(
                besides: audio, sampleRate: 44100)
        else {
            Issue.record("expected a loaded sheet")
            return
        }
        #expect(from.lastPathComponent == "Album.cue")
        #expect(parsed.markers.map(\.title) == ["One", "Two"])
        #expect(parsed.markers[1].start == 44100 * 60)
    }

    /// A multi-`FILE` album must say *why* it has no markers rather than
    /// silently having none — four of the corpus's nine sheets take this path.
    @Test("a multi-FILE sheet comes back as a named rejection, not as nothing")
    func multiFileIsReported() throws {
        let scratch = try Scratch()
        _ = try scratch.write(
            "Album.cue",
            """
            FILE "a.wav" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
            FILE "b.wav" WAVE
              TRACK 02 AUDIO
                INDEX 01 00:00:00
            """)
        let audio = try scratch.touch("Album.flac")
        guard case .rejected(let why, _) = CueSheetLoader.load(besides: audio, sampleRate: 44100)
        else {
            Issue.record("expected a rejection")
            return
        }
        #expect(why == .multipleFiles(count: 2))
    }

    // MARK: - Encodings

    /// The fallback the corpus cannot test. A strict UTF-8 decode fails outright
    /// on a perfectly valid Latin-1 sheet, and the user would see "no markers"
    /// for a file that is fine.
    @Test("a Latin-1 sheet with accented titles still loads")
    func latin1() throws {
        let scratch = try Scratch()
        let text =
            "FILE \"a.wav\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"Café Añejo\"\n"
            + "    INDEX 01 00:00:00\n"
        let data = try #require(text.data(using: .isoLatin1))
        // Confirm the fixture is genuinely not valid UTF-8, or the test proves
        // nothing about the fallback.
        #expect(String(data: data, encoding: .utf8) == nil)
        try data.write(to: scratch.url.appendingPathComponent("Album.cue"))
        let audio = try scratch.touch("Album.flac")
        guard case .loaded(let parsed, _) = CueSheetLoader.load(besides: audio, sampleRate: 44100)
        else {
            Issue.record("expected a loaded sheet")
            return
        }
        #expect(parsed.markers.count == 1)
        #expect(parsed.markers[0].title == "Café Añejo")
    }

    @Test("a UTF-16 sheet with a byte-order mark still loads")
    func utf16() throws {
        let scratch = try Scratch()
        let text =
            "FILE \"a.wav\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"Wide\"\n"
            + "    INDEX 01 00:00:00\n"
        let data = try #require(text.data(using: .utf16))
        try data.write(to: scratch.url.appendingPathComponent("Album.cue"))
        let audio = try scratch.touch("Album.flac")
        guard case .loaded(let parsed, _) = CueSheetLoader.load(besides: audio, sampleRate: 44100)
        else {
            Issue.record("expected a loaded sheet")
            return
        }
        #expect(parsed.markers[0].title == "Wide")
    }

    /// The times are what the feature is for. A sheet whose accents come out
    /// mangled still places every marker exactly right, so garbled text is a
    /// better outcome than refusing to read the file.
    @Test("bytes that are valid in no encoding still yield correctly placed markers")
    func undecodableBytesStillPlaceMarkers() throws {
        let scratch = try Scratch()
        var data = Data("FILE \"a.wav\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"".utf8)
        data.append(contentsOf: [0x81, 0xFE, 0x9D])  // not valid UTF-8
        data.append(Data("\"\n    INDEX 01 00:01:00\n".utf8))
        try data.write(to: scratch.url.appendingPathComponent("Album.cue"))
        let audio = try scratch.touch("Album.flac")
        guard case .loaded(let parsed, _) = CueSheetLoader.load(besides: audio, sampleRate: 44100)
        else {
            Issue.record("expected a loaded sheet")
            return
        }
        #expect(parsed.markers.count == 1)
        #expect(parsed.markers[0].start == 44100)
    }
}
