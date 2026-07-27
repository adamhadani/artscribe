import CoreAudio
import Foundation

/// Reads the CoreAudio HAL. Facts only — every *decision* about what these facts
/// mean lives in `OutputDeviceResolver`, which needs no hardware to test.
///
/// There is no `AVAudioSession` on macOS (it is iOS-only), so device enumeration
/// goes through `AudioObjectGetPropertyData` directly.
public enum CoreAudioHAL {

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Every device the HAL knows about, output-capable or not. Filtering is the
    /// resolver's job so that the filter itself is testable.
    ///
    /// A HAL failure yields an empty list rather than a partial one; the caller
    /// then reports "no audio output device is available", which is visible
    /// (spec §8) even though the underlying `OSStatus` is not.
    public static func allDevices() -> [AudioDevice] {
        var listAddress = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(systemObject, &listAddress, 0, nil, &size) == noErr,
            size > 0
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kAudio_ParamError }
            return AudioObjectGetPropertyData(systemObject, &listAddress, 0, nil, &size, base)
        }
        guard status == noErr else { return [] }

        return ids.map { id in
            AudioDevice(
                id: AudioDeviceIdentifier(id), rawName: name(of: id),
                outputChannelCount: outputChannelCount(of: id),
                nominalSampleRate: nominalSampleRate(of: id))
        }
    }

    public static func defaultOutputDevice() -> AudioDeviceIdentifier? {
        var deviceAddress = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            systemObject, &deviceAddress, 0, nil, &size, &device)
        guard status == noErr, device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return AudioDeviceIdentifier(device)
    }

    /// Channels on the output scope. Zero for an input-only device, which is how
    /// microphones are kept out of the output menu.
    static func outputChannelCount(of device: AudioDeviceID) -> Int {
        var configAddress = address(
            kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(device, &configAddress, 0, nil, &size) == noErr,
            size >= UInt32(MemoryLayout<AudioBufferList>.size)
        else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard
            AudioObjectGetPropertyData(device, &configAddress, 0, nil, &size, raw) == noErr
        else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func name(of device: AudioDeviceID) -> String {
        var nameAddress = address(kAudioObjectPropertyName)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &size, &value)
        guard status == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    /// The rate the device is actually running at, for reporting a mismatch with
    /// the file. Returns 0 when it cannot be read.
    public static func nominalSampleRate(of device: AudioDeviceID) -> Double {
        var rateAddress = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard
            AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &size, &rate) == noErr
        else { return 0 }
        return rate
    }
}

/// The live HAL as an `AudioDeviceSource`, including the two property listeners
/// that make the menu update while it is open: the device list itself, and which
/// device is the system default.
@MainActor
public final class CoreAudioDeviceSource: AudioDeviceSource {

    /// Holds the registered listener blocks so they can be removed exactly once,
    /// from a `deinit` that does not need main-actor isolation. A leaked HAL
    /// listener outlives the app object it was meant to notify.
    private final class Registration: @unchecked Sendable {
        private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

        func add(
            _ selector: AudioObjectPropertySelector,
            _ block: @escaping AudioObjectPropertyListenerBlock
        ) {

            var listenerAddress = CoreAudioHAL.address(selector)
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &listenerAddress, DispatchQueue.main,
                block)
            guard status == noErr else { return }
            listeners.append((listenerAddress, block))
        }

        deinit {
            for (address, block) in listeners {
                var address = address
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
            }
        }
    }

    private var registration: Registration?

    public init() {}

    public func availableDevices() -> [AudioDevice] { CoreAudioHAL.allDevices() }

    public func defaultOutputDevice() -> AudioDeviceIdentifier? {
        CoreAudioHAL.defaultOutputDevice()
    }

    /// Listens on `kAudioHardwarePropertyDevices` (plugged in / removed) and
    /// `kAudioHardwarePropertyDefaultOutputDevice` (the default changed). Both
    /// are delivered on the main queue, so the menu can update in place.
    public func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        let registration = Registration()
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { onChange() }
        }
        registration.add(kAudioHardwarePropertyDevices, block)
        registration.add(kAudioHardwarePropertyDefaultOutputDevice, block)
        self.registration = registration
    }
}
