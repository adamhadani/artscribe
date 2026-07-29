import ArtscribeKit
import Testing

@testable import ArtscribeUI

@Suite("TimeCode")
struct TimeCodeTests {

    @Test("zero reads as a full counter, not an empty string")
    func zero() {
        #expect(TimeCode.precise(seconds: 0) == "00:00.000")
        #expect(TimeCode.coarse(seconds: 0) == "00:00")
    }

    @Test("sub-second values keep millisecond resolution")
    func subSecond() {
        #expect(TimeCode.precise(seconds: 0.001) == "00:00.001")
        #expect(TimeCode.precise(seconds: 0.5) == "00:00.500")
        #expect(TimeCode.precise(seconds: 0.9999) == "00:01.000")
        #expect(TimeCode.coarse(seconds: 0.4) == "00:00")
        #expect(TimeCode.coarse(seconds: 0.6) == "00:01")
    }

    /// Rounding must carry, or the counter can show a minute that has 60 seconds.
    @Test("rounding carries into the next unit")
    func rounding() {
        #expect(TimeCode.precise(seconds: 59.9996) == "01:00.000")
        #expect(TimeCode.coarse(seconds: 59.6) == "01:00")
        #expect(TimeCode.precise(seconds: 3599.9999) == "1:00:00.000")
    }

    @Test("the hour field only appears once it is needed")
    func hours() {
        #expect(TimeCode.precise(seconds: 3599.5) == "59:59.500")
        #expect(TimeCode.precise(seconds: 3600) == "1:00:00.000")
        #expect(TimeCode.coarse(seconds: 3600) == "1:00:00")
        #expect(TimeCode.coarse(seconds: 7325) == "2:02:05")
    }

    @Test("negative values keep their sign")
    func negative() {
        #expect(TimeCode.precise(seconds: -1.25) == "-00:01.250")
        #expect(TimeCode.coarse(seconds: -90) == "-01:30")
    }

    @Test("unrepresentable values are shown as such, never as zero")
    func unrepresentable() {
        #expect(TimeCode.precise(seconds: .nan) == TimeCode.placeholder)
        #expect(TimeCode.precise(seconds: .infinity) == TimeCode.placeholder)
        #expect(TimeCode.coarse(seconds: 1e30) == TimeCode.placeholder)
    }

    @Test("frames convert through the sample rate")
    func frames() {
        #expect(TimeCode.precise(frames: 44100, sampleRate: 44100) == "00:01.000")
        #expect(TimeCode.precise(frames: 25_371_648, sampleRate: 44100) == "09:35.321")
        #expect(TimeCode.precise(frames: 1, sampleRate: 44100) == "00:00.000")
    }

    @Test("a bogus sample rate does not silently read as zero")
    func badSampleRate() {
        #expect(TimeCode.precise(frames: 1000, sampleRate: 0) == TimeCode.placeholder)
        #expect(TimeCode.seconds(frames: 1000, sampleRate: -1).isNaN)
    }
}
