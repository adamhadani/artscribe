import Testing

@testable import ArtscribeKit

/// The cue parser, against the shapes the real corpus actually contains.
///
/// Every case here was written from a survey of `~/Downloads/Gonzalo Rubalcaba`
/// — nine sheets, eight albums — rather than from the format's documentation.
/// The two differ in ways that matter: the documented format says a `FILE` line
/// names the audio, and in that corpus 21 of 30 `FILE` lines name a `.wav` that
/// no longer exists.
@Suite("Cue sheet parsing")
struct CueSheetTests {

    private static let rate: Double = 44100

    // MARK: - The time field

    /// The single easiest way to get this wrong, and the failure is quiet: the
    /// markers land in plausible places and are all slightly early.
    @Test("the third field is CD frames at 75/s, not hundredths")
    func framesAreSeventyFifths() {
        // 74 frames is one frame shy of a second — the largest legal value.
        #expect(
            CueSheet.frames(fromCueTime: "00:00:74", sampleRate: Self.rate)
                == FrameIndex((74.0 / 75.0 * 44100).rounded()))
        // Read as hundredths this would be 0.74 s = 32634 frames. It is not.
        #expect(CueSheet.frames(fromCueTime: "00:00:74", sampleRate: Self.rate) == 43512)
        #expect(CueSheet.frames(fromCueTime: "00:01:00", sampleRate: Self.rate) == 44100)
        let oneMinute: FrameIndex = 2_646_000
        #expect(CueSheet.frames(fromCueTime: "01:00:00", sampleRate: Self.rate) == oneMinute)
    }

    /// `Suite 4 y 20.cue` carries `67:30:xx`. A parser that treated minutes as a
    /// clock field would wrap that to 7 minutes and put the last five tracks of
    /// a 68-minute album inside its first eight.
    @Test("minutes are a count, not a clock field, and are not wrapped at 60")
    func minutesArePastSixty() {
        #expect(
            CueSheet.frames(fromCueTime: "67:30:00", sampleRate: Self.rate)
                == FrameIndex((67.0 * 60 + 30) * 44100))
        #expect(
            CueSheet.frames(fromCueTime: "120:00:00", sampleRate: Self.rate)
                == FrameIndex(120 * 60 * 44100))
    }

    @Test("a malformed time is rejected rather than guessed at")
    func malformedTimesAreRejected() {
        // Each of these would be a marker at frame 0 if the parser fell back to
        // zero — which reads as a real track boundary and is not one.
        #expect(CueSheet.frames(fromCueTime: "", sampleRate: Self.rate) == nil)
        #expect(CueSheet.frames(fromCueTime: "00:00", sampleRate: Self.rate) == nil)
        #expect(CueSheet.frames(fromCueTime: "00:00:00:00", sampleRate: Self.rate) == nil)
        #expect(CueSheet.frames(fromCueTime: "aa:bb:cc", sampleRate: Self.rate) == nil)
        #expect(CueSheet.frames(fromCueTime: "-1:00:00", sampleRate: Self.rate) == nil)
        // 75 frames is a second; the field only counts 0...74.
        #expect(CueSheet.frames(fromCueTime: "00:00:75", sampleRate: Self.rate) == nil)
        #expect(CueSheet.frames(fromCueTime: "00:60:00", sampleRate: Self.rate) == nil)
        // Would overflow FrameIndex on the way out: 10^13 minutes at 44.1 kHz is
        // 2.6e19 frames against an Int64 ceiling of 9.2e18. Converting anyway
        // would trap, and spec §8 says degrade visibly rather than crash.
        #expect(CueSheet.frames(fromCueTime: "9999999999999:00:00", sampleRate: Self.rate) == nil)
    }

    @Test("the sample rate is what converts, so a 48k file lands differently")
    func sampleRateScales() {
        let oneMinuteAt48k: FrameIndex = 2_880_000
        #expect(CueSheet.frames(fromCueTime: "01:00:00", sampleRate: 48000) == oneMinuteAt48k)
    }

    // MARK: - Structure

    private static let singleFile = """
        REM GENRE Jazz
        PERFORMER "Gonzalo Rubalcaba"
        TITLE "Rapsodia"
        FILE "Gonzalo Rubalcaba - Rapsodia.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Contagio"
            INDEX 00 00:00:00
            INDEX 01 00:00:33
          TRACK 02 AUDIO
            TITLE "Circuito II"
            INDEX 00 06:41:43
            INDEX 01 06:42:03
        """

    @Test("a single-FILE sheet yields one marker per track")
    func singleFileParses() throws {
        let sheet = try CueSheet.parse(Self.singleFile, sampleRate: Self.rate).get()
        #expect(sheet.markers.count == 2)
        #expect(sheet.albumTitle == "Rapsodia")
        #expect(sheet.performer == "Gonzalo Rubalcaba")
        #expect(sheet.markers.map(\.title) == ["Contagio", "Circuito II"])
        #expect(sheet.markers.map(\.number) == [1, 2])
    }

    /// The pre-gap trap. `INDEX 00` precedes the audible start, and 18 files in
    /// the corpus carry one — taking whichever index came first would start
    /// every one of those tracks seconds early.
    @Test("INDEX 01 is the start; INDEX 00 is ignored")
    func indexZeroIsThePregap() throws {
        let sheet = try CueSheet.parse(Self.singleFile, sampleRate: Self.rate).get()
        // 00:00:33 — a third of a second in — not 00:00:00.
        #expect(sheet.markers[0].start == FrameIndex((33.0 / 75.0 * 44100).rounded()))
        // 06:42:03, not 06:41:43. Twenty cue-frames apart, a quarter of a second.
        let seconds: Double = 6 * 60 + 42 + 3.0 / 75.0
        #expect(sheet.markers[1].start == FrameIndex((seconds * 44100).rounded()))
    }

    /// The single most important structural check, per the plan. Four of the
    /// nine sheets are shaped this way, and in them each `FILE`'s times restart
    /// at zero — so a parser that ignored `FILE` would pile every marker up near
    /// the beginning of whichever file happened to be open.
    @Test("a multi-FILE sheet is rejected outright, not half-parsed")
    func multipleFilesAreRejected() {
        let multi = """
            TITLE "Giraldilla"
            FILE "01 - Rumbero.wav" WAVE
              TRACK 01 AUDIO
                TITLE "Rumbero"
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                TITLE "Proyecto Latino"
                INDEX 00 11:15:25
            FILE "02 - Proyecto Latino.wav" WAVE
                INDEX 01 00:00:00
            """
        #expect(CueSheet.parse(multi, sampleRate: Self.rate) == .failure(.multipleFiles(count: 2)))
    }

    @Test("input that is not a cue sheet is named as such")
    func notACueSheet() {
        #expect(CueSheet.parse("", sampleRate: Self.rate) == .failure(.notACueSheet))
        #expect(
            CueSheet.parse("the quick brown fox\njumped", sampleRate: Self.rate)
                == .failure(.notACueSheet))
    }

    @Test("a sheet with a FILE but no usable track says so")
    func noTracks() {
        #expect(
            CueSheet.parse("FILE \"a.wav\" WAVE\n", sampleRate: Self.rate) == .failure(.noTracks))
        // A TRACK with no INDEX 01 has no position, so it cannot be placed.
        #expect(
            CueSheet.parse(
                "FILE \"a.wav\" WAVE\n  TRACK 01 AUDIO\n    INDEX 00 00:00:00\n",
                sampleRate: Self.rate) == .failure(.noTracks))
    }

    // MARK: - Real-world untidiness

    @Test("CRLF line endings and a leading BOM both parse")
    func crlfAndBom() throws {
        let text =
            "\u{FEFF}FILE \"a.wav\" WAVE\r\n  TRACK 01 AUDIO\r\n"
            + "    TITLE \"With CRLF\"\r\n    INDEX 01 00:01:00\r\n"
        let sheet = try CueSheet.parse(text, sampleRate: Self.rate).get()
        #expect(sheet.markers.count == 1)
        // The quotes go, and so does the \r that a naive split leaves behind.
        #expect(sheet.markers[0].title == "With CRLF")
        #expect(sheet.markers[0].start == 44100)
    }

    @Test("a track with no TITLE is named by its number rather than left blank")
    func untitledTrack() throws {
        let text = "FILE \"a.wav\" WAVE\n  TRACK 07 AUDIO\n    INDEX 01 00:02:00\n"
        let sheet = try CueSheet.parse(text, sampleRate: Self.rate).get()
        #expect(sheet.markers[0].title == "Track 07")
    }

    @Test("out-of-order tracks come back in time order")
    func outOfOrder() throws {
        let text = """
            FILE "a.wav" WAVE
              TRACK 02 AUDIO
                TITLE "Second"
                INDEX 01 05:00:00
              TRACK 01 AUDIO
                TITLE "First"
                INDEX 01 00:00:00
            """
        let sheet = try CueSheet.parse(text, sampleRate: Self.rate).get()
        #expect(sheet.markers.map(\.title) == ["First", "Second"])
    }

    /// Truncated downloads are common and must not take the app with them.
    @Test("truncated input degrades to whatever was complete")
    func truncated() throws {
        let text =
            "FILE \"a.wav\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"Whole\"\n"
            + "    INDEX 01 00:01:00\n  TRACK 02 AUDIO\n    TITLE \"Cut off mid-"
        let sheet = try CueSheet.parse(text, sampleRate: Self.rate).get()
        // The complete track survives; the one with no INDEX is dropped rather
        // than placed at zero.
        #expect(sheet.markers.map(\.title) == ["Whole"])
    }

    @Test("the album TITLE and a track TITLE are not confused for each other")
    func albumVersusTrackTitle() throws {
        let sheet = try CueSheet.parse(Self.singleFile, sampleRate: Self.rate).get()
        #expect(sheet.albumTitle == "Rapsodia")
        #expect(!sheet.markers.contains { $0.title == "Rapsodia" })
    }

    @Test("keywords are matched case-insensitively")
    func lowercaseKeywords() throws {
        let text =
            "file \"a.wav\" WAVE\n  track 01 AUDIO\n    title \"Quiet\"\n"
            + "    index 01 00:01:00\n"
        let sheet = try CueSheet.parse(text, sampleRate: Self.rate).get()
        #expect(sheet.markers.map(\.title) == ["Quiet"])
    }

    /// A title may legitimately contain a colon, a quote or a comma; none of
    /// those may break the field it lives in.
    @Test("punctuation inside a title survives")
    func punctuationInTitles() throws {
        let text =
            "FILE \"a.wav\" WAVE\n  TRACK 01 AUDIO\n"
            + "    TITLE \"Santo Canto (Holly Chant), Pt. 2: Reprise\"\n    INDEX 01 00:01:00\n"
        let sheet = try CueSheet.parse(text, sampleRate: Self.rate).get()
        #expect(sheet.markers[0].title == "Santo Canto (Holly Chant), Pt. 2: Reprise")
    }
}
