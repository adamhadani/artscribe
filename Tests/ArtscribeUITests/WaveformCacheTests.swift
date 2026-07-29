import CoreGraphics
import Observation
import Synchronization
import Testing

@testable import ArtscribeUI

/// Why the bitmap cache is a child `@Observable` class rather than more
/// properties on `ViewerModel`, or a struct.
///
/// The line limit was the trigger; observation granularity is the reason it was
/// worth doing rather than golfing lines. A nested struct routes every write
/// through the parent's `_modify`, which notifies **even when the value did not
/// change** — the mechanism that once invalidated an observer 62 times a second
/// and made the Output Device submenu impossible to open.
@MainActor
@Suite("Waveform cache")
struct WaveformCacheTests {

    @Test("a cache write does not wake an observer of unrelated model state")
    func writesAreScoped() {
        let model = ViewerModel()
        // `onChange` is `@Sendable`, so the flag cannot be a captured local.
        let woke = Mutex(false)
        withObservationTracking {
            _ = model.isLoading
        } onChange: {
            woke.withLock { $0 = true }
        }
        model.cache.appearance = .light
        #expect(
            !woke.withLock { $0 },
            "a theme change must not invalidate a view reading isLoading")
    }

    @Test("an observer of the cache does see its writes")
    func writesStillPropagate() {
        let model = ViewerModel()
        let woke = Mutex(false)
        withObservationTracking {
            _ = model.cache.appearance
        } onChange: {
            woke.withLock { $0 = true }
        }
        model.cache.appearance = .light
        #expect(woke.withLock { $0 }, "propagation through the child must still work")
    }

    @Test("invalidate drops both bitmaps and both keys together")
    func invalidateClearsEverything() {
        let cache = WaveformCache()
        cache.waveformImage = nil
        cache.invalidate()
        #expect(cache.waveformImage == nil)
        #expect(cache.overviewImage == nil)
        #expect(cache.renderedKey == nil)
        #expect(cache.overviewKey == nil)
    }
}
