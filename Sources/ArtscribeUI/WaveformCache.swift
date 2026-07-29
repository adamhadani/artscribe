import CoreGraphics
import Observation

/// The rasterised waveform, the overview strip, and the keys that say what they
/// were drawn from.
///
/// **A child `@Observable` class, not a struct**, and the difference is
/// measured rather than stylistic. Observation tracks per property *access*, so
/// with a nested class a view that reads only `waveformImage` is left alone when
/// `appearance` changes. A nested **struct** cannot do that: every write goes
/// through the parent's `_modify`, which notifies unconditionally — it notifies
/// even for `cache.scale = <the value it already held>`. That is the same
/// mechanism that invalidated an observer 62 times a second and made the Output
/// Device submenu impossible to open. Probed on this toolchain:
///
/// | sub-model | value changed | value unchanged | unrelated property read |
/// |---|---|---|---|
/// | nested `@Observable` class | notified | silent | silent |
/// | nested struct | notified | **notified** | — |
///
/// Domain value types (`Viewport`, `Selection`, `LoopRegion`, `SpeedState`) stay
/// structs: they live in `ArtscribeKit`, which imports nothing, and they are
/// values rather than state containers. This type is the opposite — a mutable
/// cache with one writer.
@MainActor
@Observable
public final class WaveformCache {

    /// Written only by `refresh()` in `ViewerModel+Rendering`, which is why the
    /// setter is module-internal rather than private.
    public internal(set) var waveformImage: CGImage?
    public internal(set) var overviewImage: CGImage?

    /// What each cached bitmap was drawn from. A render is skipped when the key
    /// still matches, which is the whole reason the cache exists: the waveform
    /// changes only on a viewport, size or theme change, while the playhead
    /// moves every frame and is drawn as a cheap overlay on top.
    var renderedKey: WaveformRenderer.Key?
    var overviewKey: WaveformRenderer.Key?

    /// Backing-store pixels per point. Read from the window; 2 until one says
    /// otherwise, which is right for every Mac this ships to and harmless on
    /// the rest.
    var scale: CGFloat = 2

    /// Which look the cached bitmaps were rasterised in.
    ///
    /// The model has to know the theme even though it draws nothing itself:
    /// `WaveformRenderer` writes colours straight into the bitmap, so a theme
    /// change has to invalidate the cache and re-render — and the cache key is
    /// here. The view layer pushes this in from the environment's colour scheme
    /// (`DocumentView`), which is also what makes `system` follow macOS.
    public internal(set) var appearance: Appearance = .dark

    public init() {}

    /// Drops both bitmaps and their keys, forcing the next `refresh()` to draw.
    func invalidate() {
        waveformImage = nil
        overviewImage = nil
        renderedKey = nil
        overviewKey = nil
    }
}
