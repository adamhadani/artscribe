import Foundation

public enum DecodeError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case noAudioTrack
    case unsupportedFormat(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail):
            return "This file could not be read. \(detail)"
        case .noAudioTrack:
            return "This file contains no audio track."
        case .unsupportedFormat(let detail):
            return "macOS cannot decode this file's audio format. \(detail)"
        case .cancelled:
            return "Loading was cancelled."
        }
    }
}
