/// Where each track of a one-file album begins, read from its `.cue` sheet.
///
/// A cue sheet indexes a single audio file into tracks. Live albums, DJ sets and
/// vinyl rips are commonly distributed that way, and without this Artscripture sees
/// one undifferentiated blob.
///
/// **Pure, and in `ArtscribeKit` because of it.** Parsing is `String` in,
/// `CueSheet` out — no file system, no `Foundation`, no encoding guesswork.
/// Finding the sibling file and turning its bytes into a `String` is a separate
/// job that needs `Foundation`, and lives in `CueSheetLoader`. This half is
/// where the arithmetic bugs live, so this half is the one worth testing
/// exhaustively.
public struct CueSheet: Equatable, Sendable {

    /// One track's start, already converted to frames at the audio's sample
    /// rate — the unit the rest of the app measures in.
    public struct Marker: Equatable, Sendable {
        /// Where the track begins. `INDEX 01`, never `INDEX 00`; see `parse`.
        public var start: FrameIndex
        /// The track's `TITLE`, or a generated `Track NN` when it has none.
        public var title: String
        /// The `TRACK` number as written, kept so a marker can be named even
        /// when two tracks share a title.
        public var number: Int

        public init(start: FrameIndex, title: String, number: Int) {
            self.start = start
            self.title = title
            self.number = number
        }
    }

    public var markers: [Marker]
    /// The album's own `TITLE`, above any `FILE` line. Shown nowhere yet; kept
    /// because it is free here and re-parsing to get it later would not be.
    public var albumTitle: String?
    public var performer: String?

    public init(markers: [Marker] = [], albumTitle: String? = nil, performer: String? = nil) {
        self.markers = markers
        self.albumTitle = albumTitle
        self.performer = performer
    }

    /// Why a cue sheet produced no markers. Never a crash, and never silence:
    /// spec §8 forbids degrading without saying so, and "your album has no
    /// track marks" is exactly the kind of thing a user would otherwise assume
    /// was a bug in the audio.
    public enum Rejection: Error, Equatable, Sendable {
        /// More than one `FILE`. The album is already split into per-track
        /// files, so markers inside any one of them are meaningless.
        case multipleFiles(count: Int)
        /// Parsed, but nothing usable came out.
        case noTracks
        /// Not a cue sheet at all — no `FILE`, no `TRACK`.
        case notACueSheet
    }

    /// CD frames per second. A cue sheet's third time field is **not**
    /// milliseconds and not centiseconds: it is CD sectors, of which there are
    /// exactly 75 in a second. Reading it as hundredths puts every marker
    /// plausibly but wrongly placed, which is worse than not placing it.
    public static let framesPerSecond = 75.0

    /// Parses a cue sheet's text.
    ///
    /// - Parameter sampleRate: the *audio's* sample rate, used to convert cue
    ///   time to frame positions. Passing the wrong one misplaces every marker
    ///   proportionally, so it is required rather than defaulted.
    ///
    /// Deliberate choices, each forced by the real corpus in
    /// `~/Downloads/Gonzalo Rubalcaba`:
    ///
    /// * **`INDEX 01` is the track start; `INDEX 00` is the pre-gap** and is
    ///   ignored. 18 files in that corpus carry `INDEX 00`, and taking the
    ///   first index seen would start every one of those tracks seconds early.
    /// * **A multi-`FILE` sheet is rejected outright**, not half-parsed. Four of
    ///   the nine sheets there have one `FILE` per track, and in those the times
    ///   restart at zero inside each file — so a parser that ignored `FILE`
    ///   would emit a pile of markers clustered near the start.
    /// * **Minutes are not clock minutes.** `67:30:00` is a real value in that
    ///   corpus (a 67-minute album), so the field is read as a plain count and
    ///   never taken modulo 60.
    public static func parse(_ text: String, sampleRate: Double) -> Result<CueSheet, Rejection> {
        var state = Accumulator(sampleRate: sampleRate)
        // `isNewline`, not `$0 == "\n" || $0 == "\r"`. Swift's `Character` is an
        // extended grapheme cluster and **CRLF is a single one** — neither
        // comparison matches it, so a DOS-line-ended sheet did not split at all
        // and parsed as one enormous line whose only keyword was `FILE`. Half
        // the cue sheets in the wild come from Windows rippers.
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            // A BOM survives decoding and would otherwise make the very first
            // keyword unrecognisable — the whole sheet would read as "not a cue
            // sheet" because of three invisible bytes.
            let line = rawLine.drop { $0 == "\u{FEFF}" || $0 == " " || $0 == "\t" }
            guard let keyword = firstWord(line)?.uppercased() else { continue }
            state.take(
                keyword, rest: line.dropFirst(keyword.count).drop { $0 == " " || $0 == "\t" })
        }
        return state.finish()
    }

    /// The parse in progress.
    ///
    /// A type rather than a pile of `var`s and a nested `func`, because the
    /// switch over directives was one function doing eight jobs and tripped the
    /// project's complexity limit. Each directive now reads on its own.
    private struct Accumulator {
        let sampleRate: Double
        var markers: [Marker] = []
        var albumTitle: String?
        var performer: String?
        var fileCount = 0
        var trackCount = 0
        /// `nil` until a `TRACK` line opens one. Everything after it belongs to
        /// it, which is how a title is attached to the right start.
        var number: Int?
        var title: String?
        var start: FrameIndex?
        /// Titles seen before the first `TRACK` are the album's, not a track's.
        var insideTrack = false

        mutating func take(_ keyword: String, rest: Substring) {
            switch keyword {
            // `FILE` is counted and otherwise ignored. Its name is deliberately
            // *not* used to locate the audio: across the corpus 21 FILE lines
            // say `.wav` while the audio present is `.flac` or `.ape`, because
            // EAC names the WAV it ripped to and then encoded away.
            case "FILE": fileCount += 1
            case "TRACK": openTrack(rest)
            case "TITLE": takeTitle(rest)
            case "PERFORMER": if !insideTrack { performer = unquoted(rest) }
            case "INDEX": takeIndex(rest)
            // REM is comments, ReplayGain and DISCID. The rest — PREGAP,
            // POSTGAP, FLAGS, ISRC, CATALOG, SONGWRITER — carry nothing a
            // marker needs.
            default: break
            }
        }

        private mutating func openTrack(_ rest: Substring) {
            closeTrack()
            trackCount += 1
            insideTrack = true
            number = firstWord(rest).flatMap { Int($0) } ?? trackCount
        }

        private mutating func takeTitle(_ rest: Substring) {
            if insideTrack {
                title = unquoted(rest)
            } else {
                albumTitle = unquoted(rest)
            }
        }

        private mutating func takeIndex(_ rest: Substring) {
            guard let indexNumber = firstWord(rest).flatMap({ Int($0) }) else { return }
            // 01 is the audible start. 00 is the pre-gap that precedes it.
            guard indexNumber == 1 else { return }
            let time = rest.dropFirst(firstWord(rest)?.count ?? 0).drop { $0 == " " || $0 == "\t" }
            if let frames = frames(fromCueTime: time, sampleRate: sampleRate) { start = frames }
        }

        /// A track with no `INDEX 01` has no position and is dropped rather than
        /// placed at zero, where it would read as a real boundary.
        private mutating func closeTrack() {
            defer {
                number = nil
                title = nil
                start = nil
            }
            guard let number, let start else { return }
            markers.append(
                Marker(start: start, title: title ?? "Track \(paddedTwo(number))", number: number))
        }

        mutating func finish() -> Result<CueSheet, Rejection> {
            closeTrack()
            guard fileCount > 0 || trackCount > 0 else { return .failure(.notACueSheet) }
            guard fileCount <= 1 else { return .failure(.multipleFiles(count: fileCount)) }
            guard !markers.isEmpty else { return .failure(.noTracks) }
            // Out-of-order TRACK entries are legal in the wild and meaningless
            // to draw unsorted, since every consumer walks them left to right.
            markers.sort { $0.start < $1.start }
            return .success(
                CueSheet(markers: markers, albumTitle: albumTitle, performer: performer))
        }
    }

    /// `mm:ss:ff` to frames, where `ff` is CD sectors at 75/s.
    ///
    /// Returns `nil` rather than a guess when the shape is wrong. A malformed
    /// time that silently became 0 would put a marker at the start of the file,
    /// which reads as a real track boundary and is not one.
    static func frames(fromCueTime text: some StringProtocol, sampleRate: Double) -> FrameIndex? {
        let field = text.prefix { $0 != " " && $0 != "\t" }
        let parts = field.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let minutes = Int(parts[0]), let seconds = Int(parts[1]),
            let cueFrames = Int(parts[2])
        else { return nil }
        guard minutes >= 0, seconds >= 0, cueFrames >= 0 else { return nil }
        // `seconds` is allowed past 59 and `minutes` has no ceiling at all: the
        // corpus contains 67-minute values, and treating minutes as a clock
        // field would wrap them to 7.
        guard seconds < 60, cueFrames < Int(framesPerSecond) else { return nil }
        let totalSeconds =
            Double(minutes) * 60 + Double(seconds)
            + Double(cueFrames) / framesPerSecond
        let frames = (totalSeconds * sampleRate).rounded()
        // Guarding the conversion, not the inputs: a sheet claiming 10^9
        // minutes would overflow `FrameIndex` on the way in, and spec §8 says
        // degrade visibly rather than trap.
        guard frames.isFinite, frames >= 0, frames < Double(FrameIndex.max) else { return nil }
        return FrameIndex(frames)
    }

    // MARK: - Small text helpers
    //
    // Hand-rolled because `ArtscribeKit` imports nothing — there is no
    // `components(separatedBy:)` or `trimmingCharacters` here, and adding
    // Foundation to the one module that has no dependencies to pay for one
    // trim would be the wrong trade.

    private static func firstWord(_ text: some StringProtocol) -> String? {
        let word = text.prefix { $0 != " " && $0 != "\t" }
        return word.isEmpty ? nil : String(word)
    }

    /// Strips the surrounding quotes a cue sheet puts around every string, and
    /// the trailing whitespace a CRLF file leaves behind.
    private static func unquoted(_ text: some StringProtocol) -> String? {
        var trimmed = text[...]
        while let last = trimmed.last, last == " " || last == "\t" { trimmed = trimmed.dropLast() }
        if trimmed.first == "\"", trimmed.last == "\"", trimmed.count >= 2 {
            trimmed = trimmed.dropFirst().dropLast()
        }
        return trimmed.isEmpty ? nil : String(trimmed)
    }

    private static func paddedTwo(_ value: Int) -> String {
        value >= 0 && value < 10 ? "0\(value)" : "\(value)"
    }
}
