import Foundation
import Testing

@testable import Playback

// MARK: - Synthetic device lists

private let speakers = AudioDevice(
    id: 1, rawName: "MacBook Pro Speakers", outputChannelCount: 2, nominalSampleRate: 44100)
private let display = AudioDevice(
    id: 2, rawName: "LG HDR 4K", outputChannelCount: 2, nominalSampleRate: 48000)
private let microphone = AudioDevice(
    id: 3, rawName: "MacBook Pro Microphone", outputChannelCount: 0, nominalSampleRate: 48000)
private let interface = AudioDevice(
    id: 4, rawName: "Scarlett 2i2", outputChannelCount: 2, nominalSampleRate: 96000)

private let allDevices = [speakers, display, microphone, interface]

// MARK: - Filtering and naming

@Test func onlyDevicesWithOutputStreamsAreOfferedForOutput() {
    let output = OutputDeviceResolver.outputCapable(allDevices)
    #expect(output.map(\.id) == [1, 2, 4])
    #expect(!output.contains { $0.name.contains("Microphone") })
}

@Test func aBlankDeviceNameFallsBackToTheIdentifier() {
    // The HAL can return an empty or whitespace-only name. A blank menu item is
    // unusable, so the identifier stands in rather than nothing at all.
    #expect(AudioDevice(id: 7, rawName: "", outputChannelCount: 2).name == "Unknown Device (7)")
    #expect(AudioDevice(id: 7, rawName: "   ", outputChannelCount: 2).name == "Unknown Device (7)")
}

@Test func deviceNamesAreTrimmed() {
    #expect(
        AudioDevice(id: 7, rawName: "  Scarlett 2i2 ", outputChannelCount: 2).name
            == "Scarlett 2i2")
}

// MARK: - Resolution

@Test func followingTheSystemDefaultResolvesToTheCurrentDefaultDevice() {
    let resolution = OutputDeviceResolver.resolve(
        selection: .systemDefault, devices: allDevices, systemDefault: 2, selectedName: nil)
    #expect(resolution == .use(2))
}

@Test func aPinnedDeviceResolvesToItself() {
    let resolution = OutputDeviceResolver.resolve(
        selection: .device(4), devices: allDevices, systemDefault: 2, selectedName: "Scarlett 2i2")
    #expect(resolution == .use(4))
}

@Test func aRemovedDeviceFallsBackToTheSystemDefaultAndSaysSo() {
    // Headphones unplugged mid-playback: device 4 is gone from the list.
    let remaining = [speakers, display, microphone]
    let resolution = OutputDeviceResolver.resolve(
        selection: .device(4), devices: remaining, systemDefault: 2, selectedName: "Scarlett 2i2")
    guard case .fellBack(let deviceID, let notice) = resolution else {
        Issue.record("expected a fallback, got \(resolution)")
        return
    }
    #expect(deviceID == 2)
    // Spec §8: never degrade silently. The notice must name both devices.
    #expect(notice.contains("Scarlett 2i2"))
    #expect(notice.contains("LG HDR 4K"))
}

@Test func aRemovedDeviceWithNoRememberedNameStillFallsBack() {
    let resolution = OutputDeviceResolver.resolve(
        selection: .device(99), devices: allDevices, systemDefault: 1, selectedName: nil)
    guard case .fellBack(let deviceID, let notice) = resolution else {
        Issue.record("expected a fallback, got \(resolution)")
        return
    }
    #expect(deviceID == 1)
    #expect(notice.contains("MacBook Pro Speakers"))
}

@Test func selectingAnInputOnlyDeviceFallsBackRatherThanGoingSilent() {
    // A device can lose its output streams without disappearing (an aggregate
    // being reconfigured). Present-but-not-output-capable must behave as gone.
    let resolution = OutputDeviceResolver.resolve(
        selection: .device(3), devices: allDevices, systemDefault: 1,
        selectedName: "MacBook Pro Microphone")
    guard case .fellBack(let deviceID, _) = resolution else {
        Issue.record("expected a fallback, got \(resolution)")
        return
    }
    #expect(deviceID == 1)
}

@Test func noOutputDeviceAtAllIsReportedRatherThanPlayingIntoNothing() {
    let resolution = OutputDeviceResolver.resolve(
        selection: .systemDefault, devices: [microphone], systemDefault: nil, selectedName: nil)
    guard case .unavailable(let notice) = resolution else {
        Issue.record("expected unavailable, got \(resolution)")
        return
    }
    #expect(notice.lowercased().contains("no audio output device"))
}

@Test func aSystemDefaultMissingFromTheDeviceListIsReportedNotAssumed() {
    // The two HAL properties are read separately and can disagree for a moment.
    let resolution = OutputDeviceResolver.resolve(
        selection: .systemDefault, devices: [speakers], systemDefault: 42, selectedName: nil)
    guard case .unavailable = resolution else {
        Issue.record("expected unavailable, got \(resolution)")
        return
    }
}

// MARK: - Controller, driven against a synthetic HAL

@MainActor
private final class FakeDeviceSource: AudioDeviceSource {
    var devices: [AudioDevice]
    var defaultDevice: AudioDeviceIdentifier?
    var onChange: (@MainActor () -> Void)?

    init(devices: [AudioDevice], defaultDevice: AudioDeviceIdentifier?) {
        self.devices = devices
        self.defaultDevice = defaultDevice
    }

    func availableDevices() -> [AudioDevice] { devices }
    func defaultOutputDevice() -> AudioDeviceIdentifier? { defaultDevice }
    func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }
}

@MainActor
private final class FakeOutput: AudioOutputDeviceSink {
    private(set) var applied: [AudioDeviceIdentifier] = []
    var failure: (any Error)?

    func setOutputDevice(_ id: AudioDeviceIdentifier) throws {
        if let failure { throw failure }
        applied.append(id)
    }
}

private struct SinkFailure: Error, LocalizedError {
    var errorDescription: String? { "device is busy" }
}

@MainActor
@Test func theControllerAppliesTheSelectedDeviceToTheOutput() {
    let source = FakeDeviceSource(devices: allDevices, defaultDevice: 2)
    let sink = FakeOutput()
    let controller = OutputDeviceController(source: source, output: sink)

    #expect(controller.devices.map(\.id) == [1, 2, 4])
    #expect(controller.activeDeviceID == 2)
    #expect(sink.applied == [2])

    controller.select(.device(4))
    #expect(sink.applied == [2, 4])
    #expect(controller.activeDeviceName == "Scarlett 2i2")
    #expect(controller.notice == nil)
}

@MainActor
@Test func removingTheActiveDeviceFallsBackAndPublishesANotice() {
    let source = FakeDeviceSource(devices: allDevices, defaultDevice: 2)
    let sink = FakeOutput()
    let controller = OutputDeviceController(source: source, output: sink)
    controller.select(.device(4))

    source.devices = [speakers, display, microphone]
    source.onChange?()

    #expect(controller.selection == .systemDefault)
    #expect(controller.activeDeviceID == 2)
    #expect(sink.applied == [2, 4, 2])
    #expect(controller.notice?.contains("Scarlett 2i2") == true)
}

@MainActor
@Test func followingTheSystemDefaultReappliesWhenTheDefaultChanges() {
    let source = FakeDeviceSource(devices: allDevices, defaultDevice: 2)
    let sink = FakeOutput()
    let controller = OutputDeviceController(source: source, output: sink)

    source.defaultDevice = 1
    source.onChange?()

    #expect(controller.selection == .systemDefault)
    #expect(sink.applied == [2, 1])
}

@MainActor
@Test func anUnchangedDeviceListDoesNotRestartTheOutput() {
    // Every reapply stops and restarts the audio engine, which is audible.
    // A device-list notification that changes nothing must be a no-op.
    let source = FakeDeviceSource(devices: allDevices, defaultDevice: 2)
    let sink = FakeOutput()
    let controller = OutputDeviceController(source: source, output: sink)
    source.onChange?()
    source.onChange?()
    #expect(sink.applied == [2])
    #expect(controller.activeDeviceID == 2)
}

@MainActor
@Test func aPinnedDeviceIsUnaffectedByADefaultChange() {
    let source = FakeDeviceSource(devices: allDevices, defaultDevice: 2)
    let sink = FakeOutput()
    let controller = OutputDeviceController(source: source, output: sink)
    controller.select(.device(4))
    source.defaultDevice = 1
    source.onChange?()
    #expect(controller.activeDeviceID == 4)
    #expect(sink.applied == [2, 4])
}

@MainActor
@Test func aFailedDeviceSwitchIsReportedRatherThanSwallowed() {
    let source = FakeDeviceSource(devices: allDevices, defaultDevice: 2)
    let sink = FakeOutput()
    let controller = OutputDeviceController(source: source, output: sink)
    sink.failure = SinkFailure()
    controller.select(.device(4))
    #expect(controller.notice?.contains("device is busy") == true)
}

@MainActor
@Test func attachingAnOutputLaterAppliesTheCurrentSelection() {
    // The menu exists before a track is loaded, so the controller outlives any
    // particular `AudioOutput`.
    let source = FakeDeviceSource(devices: allDevices, defaultDevice: 2)
    let controller = OutputDeviceController(source: source, output: nil)
    controller.select(.device(4))
    let sink = FakeOutput()
    controller.attach(output: sink)
    #expect(sink.applied == [4])
}

@MainActor
@Test func observingTheHalDoesNotRetainTheController() {
    // The HAL listener outlives every UI object; if the observation closure held
    // the controller strongly the whole graph would leak, and a dead controller
    // would keep switching devices.
    let source = FakeDeviceSource(devices: allDevices, defaultDevice: 2)
    var controller: OutputDeviceController? = OutputDeviceController(source: source, output: nil)
    weak let weakController = controller
    #expect(weakController != nil)
    controller = nil
    #expect(weakController == nil)
    // The stale closure must be harmless rather than a crash.
    source.onChange?()
}
