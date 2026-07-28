import ArtscribeKit
import Playback

/// Output level and mute.
///
/// Split out of `ViewerModel+Playback` — which is at the project's 400-line
/// limit — and it is the natural seam: this is the one control in the app that
/// does **not** go through the command ring. Everything in `ViewerModel+Playback`
/// speaks to the render thread; nothing here does.
extension ViewerModel {

    public func volumeUp(fine isFine: Bool) {
        applyVolume { $0.step(by: isFine ? VolumeState.fineStep : VolumeState.coarseStep) }
    }

    public func volumeDown(fine isFine: Bool) {
        applyVolume { $0.step(by: -(isFine ? VolumeState.fineStep : VolumeState.coarseStep)) }
    }

    /// What the mixer actually holds, as opposed to what the model believes it
    /// asked for. `nil` when there is no audio output at all — deliberately not
    /// 0, which would be indistinguishable from silence.
    public var outputVolume: Double? { session?.output.volume }

    /// From the slider. Takes the raw 0…1 position; `VolumeState` clamps.
    public func setVolumeLevel(_ level: Double) {
        applyVolume { $0.setLevel(level) }
    }

    public func toggleMute() {
        applyVolume { $0.toggleMute() }
    }

    /// Volume is the one control that is applied on the **main actor**, straight
    /// to the mixer, rather than through the command ring: it is not the render
    /// thread's business, and `AVAudioMixerNode` already ramps it. Nothing here
    /// depends on a track being loaded — the level is remembered for the next one.
    private func applyVolume(_ change: (inout VolumeState) -> Void) {
        var next = volume
        change(&next)
        guard next != volume else { return }
        volume = next
        session?.output.setVolume(volume.amplitude)
    }
}
