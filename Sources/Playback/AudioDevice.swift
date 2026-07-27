import Foundation

/// A CoreAudio HAL object identifier. Spelled out as `UInt32` rather than
/// importing `CoreAudio` for `AudioDeviceID` so that everything in this file
/// stays a plain value type the tests can build from nothing.
public typealias AudioDeviceIdentifier = UInt32

/// One audio device as the menu needs to see it.
///
/// Deliberately inert: no HAL calls, no caching, nothing that needs hardware.
/// `CoreAudioDeviceSource` produces these; every decision about them is made by
/// `OutputDeviceResolver`, which is pure and unit-tested against synthetic lists.
public struct AudioDevice: Sendable, Equatable, Identifiable {
    public let id: AudioDeviceIdentifier
    /// Display name, never blank — see `init`.
    public let name: String
    /// Channels on `kAudioObjectPropertyScopeOutput`. Zero means input-only:
    /// such a device must never be offered as an output.
    public let outputChannelCount: Int
    /// The device's nominal sample rate, or 0 when it could not be read. Used
    /// only to *report* a mismatch with the file, never to change behaviour.
    public let nominalSampleRate: Double

    /// - Parameter rawName: exactly what `kAudioObjectPropertyName` returned.
    ///   The HAL is entitled to return an empty string, and a blank menu item is
    ///   unusable, so the identifier stands in.
    public init(
        id: AudioDeviceIdentifier, rawName: String, outputChannelCount: Int,
        nominalSampleRate: Double = 0
    ) {
        self.id = id
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed.isEmpty ? "Unknown Device (\(id))" : trimmed
        self.outputChannelCount = outputChannelCount
        self.nominalSampleRate = nominalSampleRate
    }

    public var hasOutput: Bool { outputChannelCount > 0 }
}

/// What the user asked for, which is not the same as what is currently in use.
///
/// `systemDefault` follows `kAudioHardwarePropertyDefaultOutputDevice` as it
/// changes; it is the default because it is what a user expects when they plug
/// in headphones mid-session.
public enum OutputDeviceSelection: Sendable, Equatable, Hashable {
    case systemDefault
    case device(AudioDeviceIdentifier)
}

/// The outcome of matching a selection against the devices that actually exist.
public enum OutputDeviceResolution: Sendable, Equatable {
    /// Route to this device; the selection was honoured.
    case use(AudioDeviceIdentifier)
    /// The selected device is gone. Route to `to` instead and show `notice`.
    case fellBack(to: AudioDeviceIdentifier, notice: String)
    /// There is nowhere to play. Show `notice`; do not pretend to be playing.
    case unavailable(notice: String)
}

/// Every decision about output devices lives here, in a pure function of a
/// device list. The HAL glue (`CoreAudioDeviceSource`) only *gathers* facts and
/// the SwiftUI menu only *renders* them, so neither needs hardware to be tested
/// and neither can quietly grow a policy of its own.
public enum OutputDeviceResolver {

    /// Devices that can actually play sound. A microphone must not appear in an
    /// output menu.
    public static func outputCapable(_ devices: [AudioDevice]) -> [AudioDevice] {
        devices.filter(\.hasOutput)
    }

    /// - Parameters:
    ///   - selection: what the user asked for.
    ///   - devices: every device the HAL currently reports (filtered here).
    ///   - systemDefault: `kAudioHardwarePropertyDefaultOutputDevice`, if any.
    ///   - selectedName: the last known name of the pinned device, so that a
    ///     device that has *already disappeared* can still be named in the
    ///     notice. The HAL cannot tell us the name of a device that is gone.
    public static func resolve(
        selection: OutputDeviceSelection,
        devices: [AudioDevice],
        systemDefault: AudioDeviceIdentifier?,
        selectedName: String?
    ) -> OutputDeviceResolution {
        let available = outputCapable(devices)
        let fallback = systemDefault.flatMap { id in available.first { $0.id == id } }

        switch selection {
        case .systemDefault:
            guard let fallback else { return .unavailable(notice: Self.noDeviceNotice) }
            return .use(fallback.id)

        case .device(let id):
            if let device = available.first(where: { $0.id == id }) { return .use(device.id) }
            let missing = selectedName ?? "The selected output device"
            guard let fallback else {
                return .unavailable(
                    notice: "\(missing) is no longer available, and \(Self.noDeviceNotice)")
            }
            return .fellBack(
                to: fallback.id,
                notice:
                    "\(missing) is no longer available — playback moved to the system default "
                    + "(\(fallback.name)).")
        }
    }

    static let noDeviceNotice = "No audio output device is available."
}
