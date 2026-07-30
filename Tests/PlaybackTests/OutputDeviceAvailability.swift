@testable import Playback

/// Whether an `AVAudioEngine` output graph can be built on this machine.
///
/// Both suites that build a real graph gate on this. Nothing they run starts
/// hardware or makes a sound, but the graph will not assemble at all without an
/// output device, and a headless macOS runner may have none — so they skip
/// rather than pass silently, which is the project's rule about environment
/// gates.
///
/// ## Why it is a function of the platform
///
/// This used to be `CoreAudioHAL.defaultOutputDevice() != nil`, written directly
/// into each file. `CoreAudioHAL` is inside `#if os(macOS)` — choosing an output
/// device is a macOS idea, and iOS gets whatever route the system picked — so
/// those two files simply would not compile for a simulator, and the whole of
/// `PlaybackTests` was excluded from the iOS run because of one expression.
///
/// That was the wrong thing to lose. `AudioOutputInterruptionTests` is the suite
/// about **being interrupted**, which is an iOS concern that does not exist on
/// macOS; running it only on the Mac tested the translation layer everywhere
/// except the platform it was written for.
///
/// On iOS the answer is simply yes. There is always a route — speaker, receiver,
/// or whatever is plugged in — and `AVAudioSession` is what decides it, not a
/// device enumeration this could ask.
enum OutputDeviceAvailability {
    static let hasOutputDevice: Bool = {
        #if os(macOS)
        return CoreAudioHAL.defaultOutputDevice() != nil
        #else
        return true
        #endif
    }()
}
