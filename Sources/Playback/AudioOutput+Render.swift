import AVFAudio
import Foundation

/// The render block: the one part of `AudioOutput` that runs on the CoreAudio
/// render thread.
///
/// Its own file because it plays by different rules from everything else in the
/// class. Spec §5: no allocation, no locks, no `async`/`await`, no actor access,
/// no Swift retain/release, no Foundation collections, no `String`. Every other
/// member of `AudioOutput` is `@MainActor` and may do all of those freely, and a
/// file boundary is a cheap way to keep a main-actor convenience from being added
/// here by reflex.
///
/// Nothing in here touches `self`.
extension AudioOutput {

    /// Built as a static function so the block captures exactly four values and
    /// never `self` — `self` is main-actor isolated, and touching it from the
    /// render thread would be both a concurrency violation and ARC traffic.
    ///
    /// `unowned(unsafe)` on both objects: they are owned by the `AudioOutput`
    /// that owns this block and cannot outlive it, because `deinit` stops the
    /// engine (tearing the block down) before releasing either.
    static func makeRenderBlock(
        engine: PlaybackEngine, context: RenderContext, channels: Int,
        into pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    ) -> AVAudioSourceNodeRenderBlock {
        { [unowned(unsafe) engine, unowned(unsafe) context] _, _, frameCount, rawList in
            let buffers = UnsafeMutableAudioBufferListPointer(rawList)
            let frames = Int(frameCount)

            // `standardFormatWithSampleRate` is *deinterleaved* float, so this
            // should always be one single-channel buffer per channel. Verified
            // by `eachChannelLandsInItsOwnBuffer`, but not assumed here: if the
            // layout were ever anything else, the per-channel mapping below
            // would write channel 1 into channel 0's buffer and past its end.
            // Exactly one buffer per channel, no more: a longer list would leave
            // buffers we never wrote, and undefined memory is worse than silence.
            var planar = buffers.count == channels
            if planar {
                for i in 0..<channels where !Self.isPlanarFloat(buffers[i], frames: frames) {
                    planar = false
                }
            }
            guard planar else {
                for i in 0..<buffers.count {
                    if let data = buffers[i].mData {
                        memset(data, 0, Int(buffers[i].mDataByteSize))
                    }
                }
                context.layoutMismatches.wrappingAdd(1, ordering: .relaxed)
                return noErr
            }

            for i in 0..<channels {
                pointers[i] = buffers[i].mData?.assumingMemoryBound(to: Float.self)
            }
            _ = engine.render(into: pointers, frames: frames)

            // The silence gate (see `OutputAudibility`). Deliberately *after* the
            // render: the engine still advances, so the position it publishes is
            // still real time and every position-based check still measures the
            // real render thread — only the samples are discarded. This node is
            // the graph's one signal source, so zeros here are silence at the DAC.
            if context.audibility.isSilenced {
                for i in 0..<channels {
                    if let channel = pointers[i] {
                        memset(channel, 0, frames * MemoryLayout<Float>.size)
                    }
                }
            }
            return noErr
        }
    }

    @inline(__always)
    static func isPlanarFloat(_ buffer: AudioBuffer, frames: Int) -> Bool {
        buffer.mNumberChannels == 1
            && Int(buffer.mDataByteSize) >= frames * MemoryLayout<Float>.size
    }

}
