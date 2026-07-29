import ArtscribeKit
import Foundation

/// Finds the cue sheet that belongs to an audio file, and gets its bytes into a
/// `String` the pure parser can read.
///
/// Split from `CueSheet` because this half needs `Foundation` and a file system
/// and the parser needs neither. It is also the half with no arithmetic in it:
/// everything here is naming and encodings, which fail in ways you can see.
public enum CueSheetLoader {

    /// What was found, or why nothing was.
    public enum Outcome: Equatable, Sendable {
        case none
        case loaded(CueSheet, from: URL)
        case rejected(CueSheet.Rejection, from: URL)
        case unreadable(String, from: URL)
    }

    /// Looks beside `audio` for its cue sheet and parses it.
    ///
    /// - Parameter sampleRate: the audio's real sample rate. A cue sheet has no
    ///   idea what it is indexing, so this cannot be inferred.
    public static func load(besides audio: URL, sampleRate: Double) -> Outcome {
        guard let candidate = candidates(besides: audio).first else { return .none }
        guard let data = try? Data(contentsOf: candidate) else {
            return .unreadable("the file could not be read", from: candidate)
        }
        guard let text = decode(data) else {
            return .unreadable("its text encoding was not recognised", from: candidate)
        }
        switch CueSheet.parse(text, sampleRate: sampleRate) {
        case .success(let sheet): return .loaded(sheet, from: candidate)
        case .failure(let why): return .rejected(why, from: candidate)
        }
    }

    /// Every cue sheet beside `audio` that could be its own, best first.
    ///
    /// **`FILE`'s name is deliberately not consulted.** Across the reference
    /// corpus 21 of 30 `FILE` lines name a `.wav` that no longer exists — EAC
    /// writes the name of the file it ripped to, which is then encoded to FLAC
    /// and deleted. Matching on it would find nothing for most real albums.
    ///
    /// The order is fixed rather than "whichever the directory lists first",
    /// because `Suite 4 y 20.cue` and `Suite 4 y 20.ape.cue` sit side by side in
    /// that corpus, as do `XXI Century.FLAC.cue` and `XXI Century.WAV.cue`. Two
    /// candidates must resolve the same way on every machine and every launch:
    ///
    /// 1. `<basename>.<audio extension>.cue` — the most specific, and names the
    ///    format actually in hand (`XXI Century.FLAC.cue` for a `.flac`).
    /// 2. `<basename>.cue` — the plain sibling.
    /// 3. any other `.cue` whose basename starts with the audio's, alphabetically.
    /// 4. a lone `.cue` in the directory, whatever it is called — a
    ///    one-album-per-folder rip where the cue was named after the album and
    ///    the audio after the track.
    static func candidates(besides audio: URL) -> [URL] {
        let directory = audio.deletingLastPathComponent()
        let base = audio.deletingPathExtension().lastPathComponent
        let audioExtension = audio.pathExtension
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        // `.cue` and `.CUE` both occur in the corpus.
        let sheets = entries.filter { $0.pathExtension.lowercased() == "cue" }
        guard !sheets.isEmpty else { return [] }

        func named(_ name: String) -> URL? {
            sheets.first { $0.lastPathComponent.lowercased() == name.lowercased() }
        }

        var ordered: [URL] = []
        if !audioExtension.isEmpty, let exact = named("\(base).\(audioExtension).cue") {
            ordered.append(exact)
        }
        if let plain = named("\(base).cue") { ordered.append(plain) }
        let prefixed = sheets.filter {
            $0.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(base.lowercased())
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        ordered.append(contentsOf: prefixed)
        if sheets.count == 1 { ordered.append(contentsOf: sheets) }
        // Stable, and each candidate only once.
        var seen: Set<String> = []
        return ordered.filter { seen.insert($0.path).inserted }
    }

    /// Bytes to text, trying the encodings cue sheets are actually written in.
    ///
    /// A strict UTF-8 decode fails outright on a perfectly valid Latin-1 sheet,
    /// and the user sees "no track markers" for a file that is fine. The order
    /// matters and is not arbitrary:
    ///
    /// * **UTF-8 first.** Correct for anything modern, and it *fails loudly* on
    ///   non-UTF-8 input rather than producing mojibake, which is what makes it
    ///   safe to try first.
    /// * **UTF-16 next**, but only when a byte-order mark says so. Without a BOM
    ///   the guess is unreliable and would happily "succeed" on Latin-1.
    /// * **Shift-JIS**, which Japanese rips are commonly in. Tried before
    ///   Latin-1 because Latin-1 can never fail, so anything after it is dead
    ///   code.
    /// * **Windows-1252**, which is what "Latin-1" nearly always means in
    ///   practice on files from Windows rippers — it fills 0x80–0x9F with the
    ///   curly quotes and dashes that ISO-8859-1 leaves as control codes.
    /// * **ISO-8859-1 last, as the floor that cannot fail.** Every one of the
    ///   256 byte values maps to a character, so this always returns text.
    ///   Windows-1252 is *not* that floor — five of its byte values (0x81,
    ///   0x8D, 0x8F, 0x90, 0x9D) are undefined and decoding returns `nil`, which
    ///   a test caught by feeding it 0x81. Ending on it would have turned an
    ///   odd byte into "no markers for this album".
    ///
    /// Garbled text is the right trade here: a sheet whose accents come out
    /// wrong still places every marker in exactly the right spot, and the times
    /// are what the feature is for.
    ///
    /// The reference corpus is entirely US-ASCII and therefore exercises **none**
    /// of the fallbacks; they are covered by synthetic fixtures instead.
    static func decode(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        let bom = data.prefix(2)
        if bom == Data([0xFF, 0xFE]) || bom == Data([0xFE, 0xFF]) {
            if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        }
        if let sjis = String(data: data, encoding: .shiftJIS) { return sjis }
        if let cp1252 = String(data: data, encoding: .windowsCP1252) { return cp1252 }
        return String(data: data, encoding: .isoLatin1)
    }
}
