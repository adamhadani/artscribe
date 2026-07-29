import AVFoundation
import ArtscribeKit
import CoreMedia
import Foundation
import os

public enum AudioFileDecoder {

    private static let logger = Logger(subsystem: "com.artscribe.AudioDecode", category: "decode")

    /// Decodes an entire file to planar Float32.
    ///
    /// Requests **interleaved** Float32 from AVAssetReader (universally supported)
    /// and de-interleaves with a strided copy. Requesting non-interleaved output
    /// directly is not reliable across all codecs.
    public static func decode(
        url: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> DecodedAudio {
        try await decode(url: url, progress: progress, initialCapacityHint: nil)
    }

    /// Test seam: `initialCapacityHint`, when non-nil, replaces the duration-based
    /// capacity estimate outright. This lets tests force an undersized initial
    /// allocation to prove the decoder grows storage rather than truncating,
    /// without needing a pathological fixture whose container metadata
    /// understates its real length. Not part of the public API.
    static func decode(
        url: URL,
        progress: (@Sendable (Double) -> Void)?,
        initialCapacityHint: Int?
    ) async throws -> DecodedAudio {
        let asset = AVURLAsset(url: url)
        let (track, format) = try await loadTrackAndFormat(asset: asset)
        let reader = try makeReader(asset: asset, track: track, format: format)

        let estimatedFrames =
            initialCapacityHint
            ?? (Int(format.duration.seconds * format.sampleRate) + Int(format.sampleRate))
        let storage = AudioStorage(
            channels: format.channels, capacityFrames: max(estimatedFrames, 1))

        let written = try await readAllSamples(
            using: reader, into: storage,
            channels: format.channels, estimatedFrames: estimatedFrames, progress: progress)

        guard written > 0 else { throw DecodeError.unsupportedFormat("Decoded zero frames.") }
        progress?(1.0)
        return DecodedAudio(
            channels: format.channels, sampleRate: format.sampleRate,
            frameCount: FrameIndex(written), storage: storage)
    }

    // MARK: - Setup

    private struct StreamFormat {
        let duration: CMTime
        let sampleRate: Double
        let channels: Int
    }

    private static func loadTrackAndFormat(asset: AVURLAsset) async throws -> (
        track: AVAssetTrack, format: StreamFormat
    ) {
        let tracks: [AVAssetTrack]
        let duration: CMTime
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
        } catch {
            throw DecodeError.unreadable(error.localizedDescription)
        }
        guard let track = tracks.first else { throw DecodeError.noAudioTrack }

        let formatDescriptions: [CMFormatDescription]
        do {
            formatDescriptions = try await track.load(.formatDescriptions)
        } catch {
            throw DecodeError.unreadable(error.localizedDescription)
        }

        guard
            let asbd = formatDescriptions.first.flatMap({
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
            })
        else {
            throw DecodeError.unsupportedFormat("No stream description available.")
        }

        let sampleRate = asbd.mSampleRate
        let channels = Int(asbd.mChannelsPerFrame)
        guard sampleRate > 0, channels > 0 else {
            throw DecodeError.unsupportedFormat(
                "Reported \(channels) channels at \(sampleRate) Hz.")
        }
        let format = StreamFormat(duration: duration, sampleRate: sampleRate, channels: channels)
        return (track, format)
    }

    private static func makeReader(
        asset: AVURLAsset, track: AVAssetTrack, format: StreamFormat
    ) throws -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw DecodeError.unreadable(error.localizedDescription)
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw DecodeError.unsupportedFormat("Reader rejected Float32 output.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw DecodeError.unreadable(
                reader.error?.localizedDescription ?? "Reader failed to start.")
        }
        return (reader, output)
    }

    // MARK: - Reading

    private static func readAllSamples(
        using reader: (reader: AVAssetReader, output: AVAssetReaderTrackOutput),
        into storage: AudioStorage,
        channels: Int,
        estimatedFrames: Int,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Int {
        var written = 0
        var emptyBufferCount = 0
        let scratch = SampleScratch()
        let frameSize = MemoryLayout<Float>.size * channels

        while let sample = reader.output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sample) }
            guard let block = CMSampleBufferGetDataBuffer(sample) else {
                // A `CMSampleBuffer` with no data buffer carries no audio payload at
                // all -- some containers emit these as markers around a mid-stream
                // format-description change. There is nothing to lose by skipping
                // one, but a *run* of them would be a symptom of something else
                // going wrong, so this is counted and logged rather than silently
                // discarded.
                emptyBufferCount += 1
                continue
            }

            let byteCount = try copyBytes(from: block, into: scratch)
            guard byteCount > 0 else {
                // A genuinely zero-length block buffer: same reasoning as above,
                // no payload existed to lose.
                emptyBufferCount += 1
                continue
            }
            // LPCM sample buffers from AVFoundation are always frame-aligned; a
            // partial frame here would mean real decoded bytes exist that don't
            // fit our layout assumptions. Never silently drop them -- throw
            // instead of truncating via integer division.
            let frames = try frameCount(inByteCount: byteCount, frameSize: frameSize)

            // Never silently truncate: if the file turns out longer than the
            // duration-based estimate predicted, grow rather than stop early.
            if written + frames > storage.capacityFrames {
                storage.grow(toAtLeast: written + frames, preserving: written)
            }
            deinterleave(scratch, frames: frames, channels: channels, into: storage, at: written)
            written += frames

            if let progress, estimatedFrames > 0 {
                progress(min(1.0, Double(written) / Double(estimatedFrames)))
            }
            if Task.isCancelled {
                reader.reader.cancelReading()
                throw DecodeError.cancelled
            }
        }

        if reader.reader.status == .failed {
            throw DecodeError.unreadable(
                reader.reader.error?.localizedDescription ?? "Decode failed.")
        }
        if emptyBufferCount > 0 {
            logger.notice(
                "Skipped \(emptyBufferCount) empty sample buffer(s) with no audio payload.")
        }
        return written
    }

    /// Computes how many complete `frameSize`-byte frames are present in
    /// `byteCount` bytes of already-known-nonempty decoded audio data.
    ///
    /// LPCM sample buffers handed back by `AVAssetReaderTrackOutput` are always
    /// frame-aligned, so `byteCount` not dividing evenly means our assumptions
    /// about this stream's layout are wrong. The previous implementation
    /// computed `byteCount / frameSize` and silently ignored any remainder --
    /// exactly the kind of silent data loss this project doesn't allow, so this
    /// throws instead.
    static func frameCount(inByteCount byteCount: Int, frameSize: Int) throws -> Int {
        precondition(frameSize > 0)
        let frames = byteCount / frameSize
        guard byteCount == frames * frameSize else {
            throw DecodeError.unsupportedFormat(
                "Decoded \(byteCount) bytes, which is not a whole multiple of the "
                    + "\(frameSize)-byte frame size.")
        }
        return frames
    }

    /// Stride-copies channel `c` out of the packed interleaved frame stream held
    /// in `scratch`. (Accelerate's `cblas_scopy` is deprecated on this SDK in
    /// favour of an ILP64 interface; a plain loop avoids that churn entirely,
    /// and `-O` can vectorise this since `dst`/`floats` are raw, unchecked
    /// pointers.)
    private static func deinterleave(
        _ scratch: SampleScratch, frames: Int, channels: Int, into storage: AudioStorage,
        at written: Int
    ) {
        let floats = scratch.buffer.bindMemory(to: Float.self, capacity: frames * channels)
        for c in 0..<channels {
            let dst = storage.pointer(c) + written
            for i in 0..<frames {
                dst[i] = floats[i * channels + c]
            }
        }
    }

    /// A single raw scratch allocation reused across every sample buffer in one
    /// decode, growing (never shrinking) as needed.
    ///
    /// Previously each chunk allocated a fresh `[Int8](repeating: 0, count:
    /// length)` -- zero-initialising memory that `CMBlockBufferCopyDataBytes`
    /// was about to overwrite in full, plus a fresh heap allocation every
    /// iteration. Profiling a real ~9.5 minute 24-bit FLAC decode (release
    /// build) showed that work was never the bottleneck (~3% of total decode
    /// time; `AVAssetReader.startReading()` and the codec's own per-chunk work
    /// inside `copyNextSampleBuffer()` account for the other ~97% and are
    /// outside this module's control), but it was real, avoidable waste, so
    /// it's removed regardless.
    final class SampleScratch {
        private(set) var buffer: UnsafeMutableRawPointer
        private(set) var capacity: Int

        init() {
            capacity = 0
            buffer = UnsafeMutableRawPointer.allocate(
                byteCount: 1, alignment: MemoryLayout<Float>.alignment)
        }

        deinit { buffer.deallocate() }

        func reserve(_ byteCount: Int) {
            guard byteCount > capacity else { return }
            buffer.deallocate()
            buffer = UnsafeMutableRawPointer.allocate(
                byteCount: byteCount, alignment: MemoryLayout<Float>.alignment)
            capacity = byteCount
        }
    }

    /// Copies the full logical contents of a `CMBlockBuffer` into `scratch`
    /// (growing it if necessary) and returns the number of bytes copied.
    ///
    /// `CMBlockBufferGetDataPointer`'s `totalLengthOut` reports the buffer's
    /// entire logical length, but the pointer it hands back is only guaranteed
    /// contiguous for `lengthAtOffsetOut` bytes from the requested offset. A
    /// `CMBlockBuffer` composed of multiple non-contiguous memory blocks (which
    /// CoreMedia can and does produce, e.g. from compressed-audio decoders) will
    /// report `lengthAtOffsetOut < totalLengthOut`; naively reading `totalLength`
    /// bytes starting at that pointer walks off the end of the first segment.
    /// `CMBlockBufferCopyDataBytes` is the API documented to read correctly
    /// across segment boundaries, so it's used unconditionally here rather than
    /// only in a fallback path.
    static func copyBytes(from block: CMBlockBuffer, into scratch: SampleScratch) throws -> Int {
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return 0 }
        scratch.reserve(length)
        let status = CMBlockBufferCopyDataBytes(
            block, atOffset: 0, dataLength: length, destination: scratch.buffer)
        guard status == noErr else {
            throw DecodeError.unreadable(
                "Could not read decoded audio samples (OSStatus \(status)).")
        }
        return length
    }
}
