import ArtscribeKit

/// The source feed: the only place on the render path that reads sample data, and the
/// loop wrap. Split out of `PlaybackEngine.swift` for the reason
/// `PlaybackEngine+Position.swift` records — that file is the most safety-critical in the
/// project and has to stay short enough to read in one sitting.
///
/// Everything here runs on the render thread under the same rules as `render` itself: no
/// allocation, no locks, no ARC, no Foundation collections, no `String`.
///
/// The members it reaches for are `internal` rather than `private` only because Swift's
/// `private` is file-scoped; they stay render-thread-owned and nothing else writes them.
extension PlaybackEngine {

    /// The one place on the render path that reads source audio.
    ///
    /// Stem separation (spec §11.3) replaces the single `sourceChannels` table with N stem
    /// tables summed here; no other part of the render path reads samples, so that swap
    /// stays contained. Nothing is built for it now.
    @inline(__always)
    func copySource(from frame: FrameIndex, into offset: Int, count: Int) {
        let base = Int(frame)
        for c in 0..<channelCount {
            guard let src = sourceChannels[c], let dst = feedChannels[c] else { continue }
            (dst + offset).update(from: src + base, count: count)
        }
    }

    /// Pushes one block of source into the stretcher, wrapping across the loop boundary
    /// **without** resetting (spec §5.1). Returns false when there is nothing left to feed.
    ///
    /// ## The loop captures on arrival, not on entry (spec §5.1)
    ///
    /// An explicit seek is honoured, so the segment being fed ends at the out point only
    /// while the out point is still *ahead* of the cursor; once the cursor is at or past
    /// it, the segment ends at the end of the file. Decided once per call, in `captured`.
    /// Before the loop → plays on and is caught at the out point; inside → loops; after →
    /// plays to the end of the file. What Ableton and Logic do.
    ///
    /// This replaced `if looping && readCursor >= loop.range.end { readCursor = … }`
    /// evaluated *before* the segment end was chosen, which snapped a cursor past the out
    /// point backwards on the very next feed — read as being yanked — while leaving a
    /// cursor before the in point alone. One line, two experiences; the user overruled both.
    ///
    /// The wrap itself only moved from the top of the next iteration to the bottom of this
    /// one, so the sequence of `copySource` calls — and the sample stream the stretcher
    /// sees — is unchanged, and the seam sweep still measures exactly zero.
    func feedSource() -> Bool {
        let required = max(1, min(stretcher.samplesRequired(), maxBlock))
        // Read once, before anything is fed: the wrap below keeps `readCursor` inside the
        // region for the rest of the call, so re-reading this would answer a different
        // question than the one that decides the segment.
        let captured = loop.isActive && readCursor < loop.range.end

        var produced = 0
        while produced < required {
            let end = captured ? loop.range.end : totalFrames
            let remaining = end - readCursor
            // Only reachable when not captured: end of file.
            if remaining <= 0 { break }
            let n = Int(min(FrameIndex(required - produced), remaining))
            copySource(from: readCursor, into: produced, count: n)
            readCursor += FrameIndex(n)
            produced += n
            // The single wrap point. `captured` implies `loop.range.count > 0` (that is
            // what `isActive` means) and `readCursor < loop.range.end` on entry, so every
            // iteration has `remaining >= 1` and `produced` strictly increases — the loop
            // cannot spin however short the region is.
            if captured && readCursor >= loop.range.end { readCursor = loop.range.start }
        }

        // Tell the stretcher the stream ended, or its tail — the last fraction of a second
        // of the file — is never flushed and the file ends early. A cursor past an active
        // loop reaches the end of the file like any other, which is the whole point of the
        // rule above.
        let atEndOfFile = !captured && readCursor >= totalFrames

        guard produced > 0 else {
            guard atEndOfFile && !sourceExhausted else { return false }
            stretcher.process(UnsafePointer(feedInput), frames: 0, final: true)
            sourceExhausted = true
            return true
        }

        stretcher.process(UnsafePointer(feedInput), frames: produced, final: atEndOfFile)
        pendingOutput += Double(produced) * timeRatio
        if atEndOfFile { sourceExhausted = true }
        return true
    }
}
