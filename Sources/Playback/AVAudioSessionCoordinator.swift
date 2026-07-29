#if os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)

import AVFAudio
import Foundation

/// `AVAudioSession`, translated into `AudioSessionEvent`.
///
/// The only file in the project that knows what an `AVAudioSession` is. It
/// makes no decisions: every notification is turned into one of the five
/// vocabulary cases and handed on, and what to *do* about it is
/// `AudioSessionPolicy`'s — which is pure, and therefore tested, on a platform
/// where this file does not even compile.
@MainActor
public final class AVAudioSessionCoordinator: AudioSessionCoordinator {

    public var onEvent: (@MainActor (AudioSessionEvent) -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var observers: [any NSObjectProtocol] = []
    private var isActive = false

    public init() {}

    /// `isolated deinit`, like `AudioOutput`'s and for the same reason: `observers`
    /// holds `any NSObjectProtocol`, which is not `Sendable`, so a nonisolated
    /// deinit cannot touch it at all under Swift 6. Removing an observer would be
    /// safe from any thread in practice, but the type system has no way to know
    /// that and `@preconcurrency` would silence a whole category of real errors to
    /// buy it.
    isolated deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// `.playback`: this app makes music the user is listening *to*, so it
    /// plays with the ring/silent switch set to silent and it does not mix
    /// with other audio.
    ///
    /// Not `.mixWithOthers`, deliberately. A transcription tool is the thing
    /// you are concentrating on; letting another app's audio sit underneath a
    /// passage being learned would defeat the purpose of the passage.
    public func configure() throws {
        try session.setCategory(.playback, mode: .default, options: [])
        observe()
    }

    public func activate() throws {
        guard !isActive else { return }
        try session.setActive(true)
        isActive = true
    }

    /// `.notifyOthersOnDeactivation` so whatever was playing before Artscribe
    /// took the session — a podcast, the Music app — gets to come back.
    ///
    /// Failure is swallowed on purpose, and it is the one place in this
    /// project that swallows anything: `setActive(false)` fails when audio is
    /// still draining, there is nothing a user could do about it, and
    /// propagating it would turn "stop playing" into an error the UI has to
    /// report. The session is reclaimed on the next `activate` regardless.
    public func deactivate() {
        guard isActive else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        isActive = false
    }

    // MARK: - Notifications

    private func observe() {
        guard observers.isEmpty else { return }
        add(AVAudioSession.interruptionNotification, Self.interruption)
        add(AVAudioSession.routeChangeNotification, Self.routeChange)
        add(AVAudioSession.mediaServicesWereResetNotification) { _ in .mediaServicesReset }
    }

    /// The raw `userInfo` is read to plain integers *inside* the delivered
    /// closure, and only those cross into the main-actor call. Passing the
    /// `Notification` itself across would be an isolation violation for the
    /// sake of two `UInt`s.
    private func add(
        _ name: Notification.Name,
        _ translate: @escaping @Sendable ([AnyHashable: Any]?) -> AudioSessionEvent?
    ) {
        let observer = NotificationCenter.default.addObserver(
            forName: name, object: session, queue: .main
        ) { [weak self] notification in
            guard let event = translate(notification.userInfo) else { return }
            MainActor.assumeIsolated { self?.onEvent?(event) }
        }
        observers.append(observer)
    }

    /// `nonisolated`, and both translators are: they run on whatever thread
    /// `NotificationCenter` delivered on, before anything crosses to the main
    /// actor. Inheriting the class's `@MainActor` would make them unusable as the
    /// `@Sendable` translator `add` takes — which is the compiler correctly
    /// pointing out that reading a dictionary is not main-actor work.
    private nonisolated static func interruption(
        _ info: [AnyHashable: Any]?
    ) -> AudioSessionEvent? {
        guard
            let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return nil }

        switch type {
        case .began:
            return .interruptionBegan
        case .ended:
            let rawOptions = info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            return .interruptionEnded(systemSuggestsResuming: options.contains(.shouldResume))
        @unknown default:
            // A type this build has never heard of. Reporting nothing is the
            // safe reading: the policy's response to an unrecognised
            // interruption would be a guess, and a wrong guess here either
            // resumes into a phone call or strands the transport.
            return nil
        }
    }

    private nonisolated static func routeChange(
        _ info: [AnyHashable: Any]?
    ) -> AudioSessionEvent? {
        guard
            let raw = info?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return nil }

        // `.oldDeviceUnavailable` is the one that matters: the headphones
        // came out. Everything else is a route the system swapped underneath
        // us, which the engine's own configuration-change notification
        // already covers.
        return reason == .oldDeviceUnavailable ? .outputDeviceDisappeared : .outputRouteChanged
    }
}

#endif
