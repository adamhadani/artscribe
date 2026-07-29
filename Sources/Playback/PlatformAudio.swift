/// The one place that chooses between the macOS and iOS implementations.
///
/// Every other file is either platform-free or entirely inside a single
/// `#if os(...)`. Concentrating the choice here is what keeps `#if` out of the
/// call sites: `ArtscribeApp` asks for *the* device source, not for a CoreAudio
/// one, and would keep compiling if it were ever built for iPadOS.
public enum PlatformAudio {

    /// The platform's audio session, or `UnmanagedAudioSession` where the
    /// platform has none.
    @MainActor
    public static func makeSession() -> any AudioSessionCoordinator {
        #if os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
        return AVAudioSessionCoordinator()
        #else
        return UnmanagedAudioSession()
        #endif
    }

    /// Where the output-device list comes from: the CoreAudio HAL on macOS, the
    /// session's current route everywhere else.
    @MainActor
    public static func makeDeviceSource() -> any AudioDeviceSource {
        #if os(macOS)
        return CoreAudioDeviceSource()
        #else
        return CurrentRouteDeviceSource()
        #endif
    }
}
