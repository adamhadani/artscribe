import Playback
import Testing

@testable import ArtscribeUI

/// Spec §8: an output device disappearing mid-session must **say so visibly**.
///
/// Before this, `devices.notice` was rendered only as a `Text` item at the
/// bottom of the Playback menu, and nothing in `ArtscribeUI` ever called
/// `clearNotice()` — so a user whose headphones vanished saw nothing at all
/// unless they happened to open that menu, and once it had been set it stayed
/// there for the rest of the session. These cover the fix: the model surfaces it
/// where the window can draw a banner, and dismissing the banner clears it.
@MainActor
@Suite("Device-loss notice")
struct DeviceNoticeTests {

    /// A synthetic HAL. `remove(_:)` is what the real thing does when headphones
    /// are unplugged: the device simply stops being in the list.
    private final class FakeDeviceSource: AudioDeviceSource {
        var devices: [AudioDevice]
        var systemDefault: AudioDeviceIdentifier?
        private var onChange: (@MainActor () -> Void)?

        init(devices: [AudioDevice], systemDefault: AudioDeviceIdentifier?) {
            self.devices = devices
            self.systemDefault = systemDefault
        }

        func availableDevices() -> [AudioDevice] { devices }
        func defaultOutputDevice() -> AudioDeviceIdentifier? { systemDefault }
        func startObserving(_ onChange: @escaping @MainActor () -> Void) {
            self.onChange = onChange
        }

        func remove(_ id: AudioDeviceIdentifier) {
            devices.removeAll { $0.id == id }
            if systemDefault == id { systemDefault = devices.first?.id }
            onChange?()
        }
    }

    private func makeController() -> (FakeDeviceSource, OutputDeviceController) {
        let source = FakeDeviceSource(
            devices: [
                AudioDevice(id: 1, rawName: "Built-in Output", outputChannelCount: 2),
                AudioDevice(id: 2, rawName: "Headphones", outputChannelCount: 2)
            ],
            systemDefault: 1)
        return (source, OutputDeviceController(source: source))
    }

    @Test("a device vanishing raises a notice the window can show, with no track loaded")
    func vanishingDeviceIsVisibleWithoutATrack() {
        let (source, devices) = makeController()
        let model = ViewerModel()
        model.attach(devices: devices)
        #expect(model.deviceNotice == nil)

        devices.select(.device(2))
        source.remove(2)

        // The display link only runs while there is a playback session, so a
        // polled notice would be invisible here. This one is read straight from
        // the `@Observable` controller.
        #expect(model.canPlay == false)
        #expect(model.deviceNotice != nil)
        #expect(model.deviceNotice?.contains("Headphones") == true)
    }

    @Test("dismissing the banner clears the notice, so it cannot sit there forever")
    func dismissClears() {
        let (source, devices) = makeController()
        let model = ViewerModel()
        model.attach(devices: devices)
        devices.select(.device(2))
        source.remove(2)
        #expect(model.deviceNotice != nil)

        model.dismissDeviceNotice()

        #expect(model.deviceNotice == nil)
        #expect(devices.notice == nil)
    }

    @Test("a model with no device controller reports no notice rather than trapping")
    func noControllerIsSafe() {
        let model = ViewerModel()
        #expect(model.deviceNotice == nil)
        model.dismissDeviceNotice()
    }
}
