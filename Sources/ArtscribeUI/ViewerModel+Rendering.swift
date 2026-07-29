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

    /// Switching theme touches nothing but the pixels: position, selection,
    /// loop, zoom and the audio graph are all untouched, so playback carries on
    /// across it.
    ///
    /// Here rather than beside its stored `appearance` because what it does is
    /// invalidate the bitmap cache, which is this file's whole subject.
    public func setAppearance(_ appearance: Appearance) {
        guard appearance != cache.appearance else { return }
        cache.appearance = appearance
        refresh()
    }

    func refresh() {
        guard let pyramid, let audio else {
            cache.waveformImage = nil
            cache.overviewImage = nil
            cache.renderedKey = nil
            cache.overviewKey = nil
            return
        }
        refreshLanes(audio: audio, pyramid: pyramid)
        refreshOverview(audio: audio, pyramid: pyramid)
    }

    private func refreshLanes(audio: DecodedAudio, pyramid: PeakPyramid) {
        let width = Int((laneSize.width * cache.scale).rounded())
        let height = Int((laneSize.height * cache.scale).rounded())
        let key = WaveformRenderer.Key(
            generation: generation,
            appearance: cache.appearance,
            startFrame: viewport.startFrame,
            framesPerPixel: viewport.framesPerPixel,
            visibleFrames: viewport.visibleFrames,
            pixelWidth: width,
            pixelHeight: height)
        guard key != cache.renderedKey else { return }
        cache.renderedKey = key
        cache.waveformImage = WaveformRenderer.render(
            audio: audio, pyramid: pyramid, key: key)
    }

    private func refreshOverview(audio: DecodedAudio, pyramid: PeakPyramid) {
        let width = Int((overviewSize.width * cache.scale).rounded())
        let height = Int((overviewSize.height * cache.scale).rounded())
        // The overview is at constant scale, so its key deliberately omits the
        // viewport: it survives every zoom and pan and is redrawn only when the
        // file, the theme, the strip size or the display scale changes.
        let key = WaveformRenderer.Key(
            generation: generation,
            appearance: cache.appearance,
            startFrame: 0,
            framesPerPixel: 0,
            visibleFrames: totalFrames,
            pixelWidth: width,
            pixelHeight: height)
        guard key != cache.overviewKey else { return }
        cache.overviewKey = key
        cache.overviewImage = WaveformRenderer.render(
            audio: audio, pyramid: pyramid, key: key)
    }
}
