#if os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)

import AVFAudio
import Foundation

/// iOS has no output *picker* for an app to own.
///
/// On macOS the app chooses a device out of everything the HAL can see. On iOS
/// and iPadOS routing belongs to the system: the user changes it in Control
/// Centre or with the AirPlay picker, and an app that tried to enumerate and
/// pin devices would be fighting the platform. So this reports exactly one
/// device — whatever the session is routed to right now — and reports it as
/// the system default, which is the truth.
///
/// That is enough for `OutputDeviceController` to work unmodified: its
/// selection stays `.systemDefault`, resolves to this one device, and its
/// device-disappeared fallback never fires because the system has already
/// picked the replacement before it tells us.
@MainActor
public final class CurrentRouteDeviceSource: AudioDeviceSource {

    /// A constant, not a HAL id: there is nothing to disambiguate, and a value
    /// that changed as the route changed would make `OutputDeviceController`
    /// stop and restart the graph on every reroute. `0` is avoided because
    /// `kAudioObjectUnknown` is 0 on the other platform and a zero id reads as
    /// "none" to anyone who has been in the macOS code.
    public static let routeIdentifier: AudioDeviceIdentifier = 1

    private let session = AVAudioSession.sharedInstance()
    private var observer: (any NSObjectProtocol)?

    public init() {}

    /// `isolated deinit` because `any NSObjectProtocol` is not `Sendable` and a
    /// nonisolated deinit may not touch it. See `AVAudioSessionCoordinator`.
    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public func availableDevices() -> [AudioDevice] {
        let route = session.currentRoute.outputs
        guard !route.isEmpty else { return [] }
        return [
            AudioDevice(
                id: Self.routeIdentifier,
                rawName: route.map(\.portName).joined(separator: " + "),
                outputChannelCount: session.outputNumberOfChannels,
                nominalSampleRate: session.sampleRate)
        ]
    }

    /// `nil` when nothing is routed, so `OutputDeviceResolver` reports "no
    /// audio output device is available" rather than pointing the graph at a
    /// device that is not there.
    public func defaultOutputDevice() -> AudioDeviceIdentifier? {
        session.currentRoute.outputs.isEmpty ? nil : Self.routeIdentifier
    }

    public func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { _ in
            // The name and channel count changed even though the identifier
            // did not, and the menu shows the name.
            MainActor.assumeIsolated { onChange() }
        }
    }
}

#endif
