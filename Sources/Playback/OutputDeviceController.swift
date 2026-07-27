import Foundation
import Observation

/// Where the device list comes from. `CoreAudioDeviceSource` is the real one;
/// the tests substitute a synthetic list so that every decision this controller
/// makes is verified without hardware.
@MainActor
public protocol AudioDeviceSource: AnyObject {
    func availableDevices() -> [AudioDevice]
    func defaultOutputDevice() -> AudioDeviceIdentifier?
    /// Calls `onChange` on the main actor whenever the device list or the system
    /// default output device changes. Implementations must not retain the
    /// closure's captured owner strongly.
    func startObserving(_ onChange: @escaping @MainActor () -> Void)
}

/// The half of `AudioOutput` this controller needs. Keeping it this narrow is
/// what lets the fallback logic be tested without an `AVAudioEngine`.
@MainActor
public protocol AudioOutputDeviceSink: AnyObject {
    func setOutputDevice(_ id: AudioDeviceIdentifier) throws
}

/// Owns the output-device *selection* and keeps the audio output pointed at
/// something that exists.
///
/// The interesting behaviour is all in `apply()`: it resolves the user's
/// selection against the devices that are actually present, and when the
/// selected device has vanished it falls back to the system default and
/// publishes a `notice`. Spec §8 forbids degrading silently, and audio simply
/// stopping when headphones are unplugged is exactly that.
@MainActor
@Observable
public final class OutputDeviceController {

    /// Output-capable devices only, in HAL order.
    public private(set) var devices: [AudioDevice] = []
    public private(set) var selection: OutputDeviceSelection = .systemDefault
    /// The device currently routed to, `nil` when there is none.
    public private(set) var activeDeviceID: AudioDeviceIdentifier?
    /// Non-`nil` when something went wrong that the user must be told about:
    /// a device disappeared, a switch failed, or there is no output at all.
    public private(set) var notice: String?

    @ObservationIgnored private let source: any AudioDeviceSource
    @ObservationIgnored private weak var output: (any AudioOutputDeviceSink)?
    /// The last name of the pinned device, remembered because the HAL cannot
    /// name a device that has already been removed.
    @ObservationIgnored private var selectedName: String?

    public init(source: any AudioDeviceSource, output: (any AudioOutputDeviceSink)? = nil) {
        self.source = source
        self.output = output
        refresh()
        source.startObserving { [weak self] in self?.refresh() }
    }

    public var activeDeviceName: String? {
        activeDeviceID.flatMap { id in devices.first { $0.id == id }?.name }
    }

    /// The device that `systemDefault` currently resolves to, for the menu.
    public var systemDefaultName: String? {
        source.defaultOutputDevice().flatMap { id in devices.first { $0.id == id }?.name }
    }

    /// Attach (or replace) the audio output. The menu exists before any track is
    /// loaded, so the selection outlives any particular `AudioOutput`.
    public func attach(output: (any AudioOutputDeviceSink)?) {
        self.output = output
        activeDeviceID = nil  // a fresh output is routed wherever the HAL defaults
        apply()
    }

    /// Clears the notice once it has been shown. The controller never clears it
    /// itself: an unread warning must not be able to scroll past.
    public func clearNotice() { notice = nil }

    public func select(_ selection: OutputDeviceSelection) {
        self.selection = selection
        if case .device(let id) = selection {
            selectedName = devices.first { $0.id == id }?.name
        } else {
            selectedName = nil
        }
        notice = nil
        apply()
    }

    /// Re-reads the HAL and re-applies the selection. Cheap when nothing
    /// changed: `apply` only touches the output when the routed device differs,
    /// because every switch stops and restarts the engine, which is audible.
    public func refresh() {
        devices = OutputDeviceResolver.outputCapable(source.availableDevices())
        apply()
    }

    private func apply() {
        let resolution = OutputDeviceResolver.resolve(
            selection: selection, devices: devices,
            systemDefault: source.defaultOutputDevice(), selectedName: selectedName)

        switch resolution {
        case .use(let id):
            route(to: id)
        case .fellBack(let id, let notice):
            // The pinned device is gone; stop pinning it, or every subsequent
            // refresh would re-report the same loss.
            selection = .systemDefault
            selectedName = nil
            self.notice = notice
            route(to: id)
        case .unavailable(let notice):
            self.notice = notice
            activeDeviceID = nil
        }
    }

    private func route(to id: AudioDeviceIdentifier) {
        guard activeDeviceID != id else { return }
        guard let output else {
            activeDeviceID = id
            return
        }
        do {
            try output.setOutputDevice(id)
            activeDeviceID = id
        } catch {
            // Never silent: a refused switch leaves the previous route in place
            // and says why.
            let name = devices.first { $0.id == id }?.name ?? "device \(id)"
            notice = "Could not switch output to \(name): \(error.localizedDescription)"
        }
    }
}
