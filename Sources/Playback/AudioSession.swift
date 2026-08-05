import Foundation

/// Something the platform did to our audio without asking.
///
/// macOS has no such concept — a Mac app owns its output until it gives it up,
/// and a route change is reported by `AVAudioEngine` itself. iOS and iPadOS
/// arbitrate between apps: a phone call, a timer, Siri, or another app claiming
/// the session will stop us mid-bar, and unplugging headphones must not move the
/// music to the built-in speaker. `AVAudioSession` announces all of it, and this
/// is that vocabulary reduced to the five things Artscripture has to answer for.
///
/// Deliberately platform-free so the policy below can be tested on the machine
/// this is developed on. The iOS notification payloads are translated into these
/// cases at the edge, in `AVAudioSessionCoordinator`.
public enum AudioSessionEvent: Sendable, Equatable, Hashable {
    /// Something took the session. Output has *already* stopped; we are being
    /// told, not asked.
    case interruptionBegan

    /// The interruption is over and the session is ours again.
    ///
    /// - Parameter systemSuggestsResuming: `AVAudioSessionInterruptionOptionShouldResume`.
    ///   The system's opinion, not permission — it is set for a timer and clear
    ///   for a phone call, and it is only half of the question.
    case interruptionEnded(systemSuggestsResuming: Bool)

    /// The device that was playing is gone: headphones unplugged, Bluetooth out
    /// of range. `AVAudioSessionRouteChangeReason.oldDeviceUnavailable`.
    case outputDeviceDisappeared

    /// Any other route change — a device appeared, the category changed, the
    /// route was overridden.
    case outputRouteChanged

    /// The media server crashed and restarted. Every audio object this process
    /// holds is now stale.
    case mediaServicesReset
}

/// What Artscripture does about an `AudioSessionEvent`.
public enum AudioSessionResponse: Sendable, Equatable, Hashable {
    /// Nothing to do.
    case none
    /// Stop the transport, and make the UI show it stopped.
    case pause
    /// Start playing again from where we were.
    case resume
    /// Tear the graph's connections down and build them back up.
    case reconfigure
}

/// The whole of Artscripture's interruption behaviour, as a pure function.
///
/// A pure function on purpose: this is the part that is easy to get wrong and
/// impossible to test on the platform where it runs. Every rule below is
/// exercised by `AudioSessionPolicyTests` on macOS, where none of the events it
/// describes can actually occur.
public enum AudioSessionPolicy {

    /// - Parameters:
    ///   - event: what the platform reported.
    ///   - wasPlaying: whether Artscripture considered itself playing immediately
    ///     before the *cause* of this event. For `interruptionEnded` that means
    ///     "was playing when the interruption began", which the caller has to
    ///     have remembered — the session cannot tell us.
    public static func response(
        to event: AudioSessionEvent, wasPlaying: Bool
    ) -> AudioSessionResponse {
        switch event {
        case .interruptionBegan:
            // Output has already stopped. The response is not to stop it — it is
            // to make our own state agree, so the transport does not sit there
            // claiming to play in silence.
            return wasPlaying ? .pause : .none

        case .interruptionEnded(let systemSuggestsResuming):
            // Both halves are required. The system's flag alone would resume a
            // track the user had paused before the interruption ever arrived;
            // `wasPlaying` alone would resume out of a phone call, which is the
            // case the flag exists to veto.
            return wasPlaying && systemSuggestsResuming ? .resume : .none

        case .outputDeviceDisappeared:
            // The one rule here that is not about correctness but about not
            // hurting anyone: headphones come out and the music must not jump to
            // the speaker. Apple's HIG requires it; it is also just decency in a
            // practice-room tool that is often running loud.
            return wasPlaying ? .pause : .none

        case .outputRouteChanged:
            // Handled a layer down: a route change that alters the format makes
            // `AVAudioEngine` post `AVAudioEngineConfigurationChange`, which
            // `AudioOutput` already observes and answers by reconnecting. Doing
            // it here as well would stop and restart the graph twice for one
            // event, which is audible.
            return .none

        case .mediaServicesReset:
            // Everything is stale whether or not we were playing, so this is the
            // one case that ignores `wasPlaying`. Rebuilding a stopped graph
            // costs nothing; leaving a stale one in place breaks the next press
            // of the space bar with no clue why.
            return .reconfigure
        }
    }
}

/// The seam between the audio graph and whatever owns the transport above it.
///
/// **Required, not optional, and that is the whole point.** `AudioOutput` used to
/// declare `onInterrupted` and `onResumeRequested` as optional properties. It
/// invoked both, documented both, and had them covered by six tests — and
/// nothing in the app ever assigned either one. So through build 166 a phone
/// call, an alarm, or another app claiming the session stopped the audio and
/// left the transport button drawn as Pause, the menu reading "Pause", and the
/// lock screen claiming to play, for ever. Nothing errored and nothing logged;
/// the user found it by switching to Spotify and switching back.
///
/// A closure that may be `nil` is a wire that may not be connected, and no test
/// of the far end can tell you whether anyone plugged it in. An `init` parameter
/// with no default is the only version of this the compiler can check.
@MainActor
public struct TransportLink {

    /// Whether the **user** considers the track playing.
    ///
    /// Deliberately not `AudioOutput.isRunning`, which is what this used to ask
    /// and is the wrong question: the graph is started the moment a track is
    /// opened and keeps running while the transport sits paused, so `isRunning`
    /// answers "yes" about a file nobody has pressed play on. An interruption
    /// that ended with `shouldResume` therefore started a track the user had
    /// never started — precisely what Apple's guidance says not to do, and the
    /// second defect found while fixing the first.
    public var isPlaying: () -> Bool

    /// The platform stopped us and the transport has to say so.
    ///
    /// The graph is already stopped by the time this runs. What the owner has to
    /// do is bring its own idea of "playing" back into line; `AudioOutput` cannot
    /// do it, because the transport state lives in `PlaybackEngine` and the model
    /// above it, and two owners of "is it playing" is how they came to disagree.
    public var onInterrupted: () -> Void

    /// The interruption is over and it is reasonable to carry on: the user was
    /// playing when it began, and the system says resuming is appropriate.
    ///
    /// A request, not an instruction, and it deliberately does not restart the
    /// graph — the owner calls its own `play`, which starts the graph on the way
    /// past and applies whatever else a resume means to it.
    public var onResumeRequested: () -> Void

    public init(
        isPlaying: @escaping () -> Bool,
        onInterrupted: @escaping () -> Void,
        onResumeRequested: @escaping () -> Void
    ) {
        self.isPlaying = isPlaying
        self.onInterrupted = onInterrupted
        self.onResumeRequested = onResumeRequested
    }

    /// For a graph with no transport above it to notify: `artscribe-cli`, which
    /// plays one file straight through on macOS, where `UnmanagedAudioSession`
    /// never posts an event for any of this to answer.
    ///
    /// Named rather than defaulted so that using it is a claim a reviewer can
    /// check, instead of an omission nobody can see.
    public static let unmanaged = TransportLink(
        isPlaying: { false }, onInterrupted: {}, onResumeRequested: {})
}

/// The platform's audio session, or the absence of one.
///
/// Owned by `AudioOutput`, which activates it around the engine's own start and
/// stop. Implementations are `@MainActor` because every caller is: the session is
/// configured, activated and torn down from the main actor, never from the render
/// thread.
@MainActor
public protocol AudioSessionCoordinator: AnyObject {
    /// Declares what this process intends to do with audio. Called once, before
    /// the first `activate`.
    func configure() throws

    /// Claims the output. Idempotent.
    func activate() throws

    /// Gives it back, so another app can have it. Idempotent, and deliberately
    /// non-throwing: a failure to deactivate is not something a user can act on
    /// and not a reason to fail a stop.
    func deactivate()

    /// Called on the main actor for every event the platform reports. Set by
    /// `AudioOutput`; implementations must not retain the closure's owner
    /// strongly.
    var onEvent: (@MainActor (AudioSessionEvent) -> Void)? { get set }
}

/// macOS: there is no session to manage.
///
/// Not a stub or a placeholder — it is the accurate model of the platform. A Mac
/// app is not arbitrated with other apps for the output device, is never
/// interrupted by a phone call, and learns about route changes from
/// `AVAudioEngineConfigurationChange`, which `AudioOutput` observes directly. So
/// every method here is correctly empty, and `onEvent` is correctly never called.
@MainActor
public final class UnmanagedAudioSession: AudioSessionCoordinator {
    public var onEvent: (@MainActor (AudioSessionEvent) -> Void)?

    public init() {}

    public func configure() throws {}
    public func activate() throws {}
    public func deactivate() {}
}
