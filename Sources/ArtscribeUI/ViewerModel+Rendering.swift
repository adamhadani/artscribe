import ArtscribeKit
import AudioDecode
import CoreGraphics
import Waveform

/// The cached-bitmap half of the model.
///
/// The performance requirement is that waveform pixels are produced once per
/// viewport change, never once per displayed frame. That is enforced structurally
/// here: `refresh()` is the only thing in the app that calls the renderer, every
/// mutating method on `ViewerModel` ends in it, and it compares a
/// `WaveformRenderer.Key` first so an unchanged view costs nothing.
extension ViewerModel {

    func refresh() {
        guard let pyramid, let audio else {
            waveformImage = nil
            overviewImage = nil
            renderedKey = nil
            overviewKey = nil
            return
        }
        refreshLanes(audio: audio, pyramid: pyramid)
        refreshOverview(audio: audio, pyramid: pyramid)
    }

    private func refreshLanes(audio: DecodedAudio, pyramid: PeakPyramid) {
        let width = Int((laneSize.width * scale).rounded())
        let height = Int((laneSize.height * scale).rounded())
        let key = WaveformRenderer.Key(
            generation: generation,
            appearance: appearance,
            startFrame: viewport.startFrame,
            framesPerPixel: viewport.framesPerPixel,
            visibleFrames: viewport.visibleFrames,
            pixelWidth: width,
            pixelHeight: height)
        guard key != renderedKey else { return }
        renderedKey = key
        waveformImage = WaveformRenderer.render(
            audio: audio, pyramid: pyramid, key: key)
    }

    private func refreshOverview(audio: DecodedAudio, pyramid: PeakPyramid) {
        let width = Int((overviewSize.width * scale).rounded())
        let height = Int((overviewSize.height * scale).rounded())
        // The overview is at constant scale, so its key deliberately omits the
        // viewport: it survives every zoom and pan and is redrawn only when the
        // file, the theme, the strip size or the display scale changes.
        let key = WaveformRenderer.Key(
            generation: generation,
            appearance: appearance,
            startFrame: 0,
            framesPerPixel: 0,
            visibleFrames: totalFrames,
            pixelWidth: width,
            pixelHeight: height)
        guard key != overviewKey else { return }
        overviewKey = key
        overviewImage = WaveformRenderer.render(
            audio: audio, pyramid: pyramid, key: key)
    }
}
