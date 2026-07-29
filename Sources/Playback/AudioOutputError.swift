import Foundation

/// What can go wrong setting up or re-routing the output graph.
///
/// Its own file, like `AudioDecode`'s `DecodeError`, and every case carries the
/// detail a user-facing message needs — spec §8 forbids failing silently, and an
/// error that cannot say *which* rate or *which* CoreAudio status was refused
/// leaves the notice with nothing to report.
public enum AudioOutputError: Error, LocalizedError, Equatable {
    case unsupportedFormat(sampleRate: Double, channels: Int)
    case noOutputUnit
    case deviceSwitchFailed(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let rate, let channels):
            return "Cannot create an output format for \(channels) channels at \(rate) Hz."
        case .noOutputUnit:
            return "The audio output unit is unavailable."
        case .deviceSwitchFailed(let status):
            return "The audio device refused the switch (CoreAudio status \(status))."
        }
    }
}
