import ArtscribeKit

/// The audible-position arithmetic, split out of `PlaybackEngine.swift` to keep that file
/// — the most safety-critical in the project — short enough to read in one sitting.
///
/// Everything here runs on the render thread under the same rules as `render` itself: no
/// allocation, no locks, no ARC, no Foundation collections. It only reads render-owned
/// state, and only scalars.
extension PlaybackEngine {

    /// The audible source position (spec §5): where the listener is, not where the feed
    /// cursor is.
    ///
    /// `readCursor` runs ahead of the sound by whatever the stretcher still holds.
    /// `pendingOutput` tracks that backlog in *output* frames — incremented by
    /// `producedFrames × timeRatio` on every feed, decremented by every frame retrieved —
    /// so dividing by `timeRatio` converts it back to source frames, and rewinding the
    /// cursor by that much lands on the next frame to be heard. Start-delay priming is
    /// excluded by construction: it is discarded without touching `pendingOutput`, because
    /// it corresponds to no source at all.
    ///
    /// Exact whenever `timeRatio` is constant. A ratio change leaves the in-flight backlog
    /// briefly mis-scaled (produced at the old ratio), an error bounded by one backlog that
    /// drains within a block or two.
    ///
    /// This is the position at the end of the block just rendered; the further offset to
    /// the DAC belongs to the output layer, which knows the device buffer size.
    func audiblePosition() -> FrameIndex {
        guard pendingOutput.isFinite, pendingOutput > 0, timeRatio > 0 else {
            return clampToFile(readCursor)
        }
        let backlog = (pendingOutput / timeRatio).rounded()
        guard backlog.isFinite, backlog >= 1 else { return clampToFile(readCursor) }
        let steps = FrameIndex(min(backlog, Double(Int32.max)))
        return clampToFile(rewind(readCursor, by: steps))
    }

    /// Walks `cursor` back `frames` source frames, *through* the loop wrap when one is
    /// active — inside a loop the source position of already-emitted output is not
    /// `cursor - frames`.
    private func rewind(_ cursor: FrameIndex, by frames: FrameIndex) -> FrameIndex {
        let range = loop.range
        guard loop.isActive, cursor >= range.start, cursor <= range.end else {
            return max(0, cursor - frames)
        }
        var offset = (cursor - range.start - frames) % range.count
        if offset < 0 { offset += range.count }
        return range.start + offset
    }

    private func clampToFile(_ frame: FrameIndex) -> FrameIndex {
        max(0, min(frame, totalFrames))
    }
}
