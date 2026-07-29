import ArtscribeKit
import AudioDecode
import Foundation
import Playback
import TimeStretch

/// `artscribe-cli` — the debug tool that makes the audio core audible.
///
/// It exists so the headless engine can be checked by ear before there is any UI
/// attached to it, and so the render-thread counters (`renderStallCount`,
/// `rejectedCommandCount`, the output layer's buffer-layout counter) have a
/// consumer: spec §8 forbids degrading silently, and a counter nobody reads is
/// only half a fix.

@MainActor
func describeDevices() {
    let devices = OutputDeviceResolver.outputCapable(CoreAudioHAL.allDevices())
    let systemDefault = CoreAudioHAL.defaultOutputDevice()
    guard !devices.isEmpty else {
        print("No audio output device is available.")
        return
    }
    print("Output devices:")
    for device in devices {
        let marker = device.id == systemDefault ? "*" : " "
        let rate =
            device.nominalSampleRate > 0
            ? String(format: "%.0f Hz", device.nominalSampleRate) : "unknown rate"
        print(
            "  \(marker) [\(device.id)] \(device.name) — \(device.outputChannelCount) ch, \(rate)")
    }
    print("  (* = system default)")
}

@MainActor
func chooseDevice(matching text: String) throws -> AudioDevice {
    let devices = OutputDeviceResolver.outputCapable(CoreAudioHAL.allDevices())
    if let id = AudioDeviceIdentifier(text), let match = devices.first(where: { $0.id == id }) {
        return match
    }
    guard
        let match = devices.first(where: {
            $0.name.range(of: text, options: .caseInsensitive) != nil
        })
    else { throw CLIError.noSuchDevice(text) }
    return match
}

/// Prints the render-thread counters whenever any of them moves. They are all
/// monotonic, so "unchanged" is genuinely nothing to report.
@MainActor
final class DegradationReporter {
    private var stalls: UInt64 = 0
    private var rejected: UInt64 = 0
    private var layout: UInt64 = 0

    func poll(engine: PlaybackEngine, output: AudioOutput) {
        report("render stalls", engine.renderStallCount, &stalls)
        report("rejected commands", engine.rejectedCommandCount, &rejected)
        report("unexpected buffer layouts", output.renderLayoutMismatchCount, &layout)
    }

    private func report(_ label: String, _ current: UInt64, _ previous: inout UInt64) {
        guard current > previous else { return }
        previous = current
        print("\n  ⚠︎ \(label): \(current)")
    }

    var summary: String? {
        guard stalls > 0 || rejected > 0 || layout > 0 else { return nil }
        return "render stalls \(stalls), rejected commands \(rejected), "
            + "unexpected buffer layouts \(layout)"
    }
}

/// One decoded track, wired to the audio graph and ready to play.
@MainActor
struct Session {
    let audio: DecodedAudio
    let ring: CommandRing
    let engine: PlaybackEngine
    let output: AudioOutput
    let devices: OutputDeviceController
}

@MainActor
func makeSession(url: URL, device: String?, speed: SpeedState) async throws -> Session {
    print("Decoding \(url.lastPathComponent)…")
    let audio = try await AudioFileDecoder.decode(url: url) { _ in }
    print(
        String(
            format: "  %.1f s, %d ch, %.0f Hz", audio.duration, audio.channels, audio.sampleRate))

    let ring = CommandRing(capacity: 64)
    let engine = PlaybackEngine(
        audio: audio, stretcher: RubberBandStretcher(engine: speed.engine), ring: ring,
        maxBlock: 1024)
    let output = try AudioOutput(
        engine: engine, sampleRate: audio.sampleRate)

    let devices = OutputDeviceController(source: CoreAudioDeviceSource(), output: output)
    if let wanted = device {
        devices.select(.device(try chooseDevice(matching: wanted).id))
    }
    if let notice = devices.notice { print("  ⚠︎ \(notice)") }
    print("Output: \(devices.activeDeviceName ?? "none")")

    return Session(
        audio: audio, ring: ring, engine: engine, output: output, devices: devices)
}

@MainActor
func startPlayback(_ session: Session, options: CommandLineOptions, speed: SpeedState) throws {
    session.ring.push(.setTimeRatio(speed.timeRatio))
    if let start = options.loopStartSeconds, let end = options.loopEndSeconds {
        let startFrame = FrameIndex(start * session.audio.sampleRate)
        let endFrame = FrameIndex(end * session.audio.sampleRate)
        session.ring.push(
            .setLoop(FrameRange(start: startFrame, count: endFrame - startFrame), true))
        session.ring.push(.seek(startFrame))
        print(
            String(
                format: "Looping %.2f s – %.2f s at %.0f%% speed. Ctrl-C to stop.", start, end,
                speed.ratio * 100))
    } else {
        print(String(format: "Playing at %.0f%% speed. Ctrl-C to stop.", speed.ratio * 100))
    }

    session.ring.push(.setPlaying(true))
    try session.output.start()

    // The device may not run at the file's rate: 44.1 kHz material on a 48 kHz
    // interface is the common case. `AVAudioEngine` resamples (measured: peak
    // exactly on pitch, worst artefact −102 dBFS, 0.27 ms added), but the user
    // is told rather than left to wonder.
    if session.output.needsSampleRateConversion() {
        print(
            String(
                format: "  note: device runs at %.0f Hz and the file is %.0f Hz, so the graph "
                    + "is resampling.", session.output.deviceSampleRate,
                session.audio.sampleRate))
    }
}

@MainActor
func followPlayback(_ session: Session, switchAfter: Double?) async throws {
    let reporter = DegradationReporter()
    var switchDeadline = switchAfter.map { Date().addingTimeInterval($0) }
    // `.setPlaying(true)` only becomes observable once the render thread has
    // drained the ring, which has not happened by the time `start()` returns.
    // Polling `isPlaying` as the loop's entry condition therefore exits
    // immediately about half the time — measured, not theorised. Wait for the
    // engine to confirm it started, and say so if it never does.
    let startDeadline = Date().addingTimeInterval(2)
    var confirmedStart = false
    var routedTo = session.devices.activeDeviceName

    while true {
        if session.engine.isPlaying {
            confirmedStart = true
        } else if confirmedStart {
            break
        } else if Date() > startDeadline {
            print("\n  ⚠︎ the render thread never started playing — nothing was heard.")
            break
        }

        if let deadline = switchDeadline, Date() >= deadline {
            switchDeadline = nil
            switchToNextDevice(
                devices: session.devices, engine: session.engine, audio: session.audio)
        }
        let seconds = Double(session.engine.currentFrame) / session.audio.sampleRate
        print(String(format: "\r  %6.2f s", seconds), terminator: "")
        fflush(stdout)
        reporter.poll(engine: session.engine, output: session.output)
        // The HAL can re-route us without being asked — the system default
        // changed, or the pinned device went away. Say so when it happens.
        if session.devices.activeDeviceName != routedTo {
            routedTo = session.devices.activeDeviceName
            print("\n  output now: \(routedTo ?? "none")")
        }
        if let notice = session.devices.notice {
            print("\n  ⚠︎ \(notice)")
            session.devices.clearNotice()
        }
        if let notice = session.output.notice {
            print("\n  ⚠︎ \(notice)")
            session.output.clearNotice()
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    session.output.stop()
    print("\nDone.")
    if let summary = reporter.summary { print("Degradation counters: \(summary)") }
}

@MainActor
func run() async throws {
    let options = try CommandLineOptions.parse(CommandLine.arguments)
    if options.listDevices {
        describeDevices()
        return
    }
    guard let url = options.file else { throw CLIError.noFile }

    var speed = SpeedState()
    speed.setRatio(options.speed)
    if speed.ratio != options.speed {
        print(String(format: "Speed clamped to %.2f×.", speed.ratio))
    }

    let session = try await makeSession(url: url, device: options.device, speed: speed)
    try startPlayback(session, options: options, speed: speed)
    try await followPlayback(session, switchAfter: options.switchAfterSeconds)
}

/// Switches to the next output device in the list mid-playback, and prints the
/// position either side of the switch. This is how "a device change preserves
/// position, speed and loop" is checked against real hardware rather than
/// asserted.
@MainActor
func switchToNextDevice(
    devices: OutputDeviceController, engine: PlaybackEngine, audio: DecodedAudio
) {
    let list = devices.devices
    guard list.count > 1, let current = devices.activeDeviceID,
        let index = list.firstIndex(where: { $0.id == current })
    else {
        print("\n  only one output device; nothing to switch to")
        return
    }
    let next = list[(index + 1) % list.count]
    let before = Double(engine.currentFrame) / audio.sampleRate
    devices.select(.device(next.id))
    let after = Double(engine.currentFrame) / audio.sampleRate
    print(
        String(
            format: "\n  switched to %@ — position %.3f s → %.3f s, still playing: %@", next.name,
            before, after, engine.isPlaying ? "yes" : "no"))
    if let notice = devices.notice { print("  ⚠︎ \(notice)") }
}

do {
    try await run()
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
