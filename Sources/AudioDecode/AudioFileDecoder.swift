import AVFoundation
import ArtscribeKit
import CoreMedia
import Foundation

public enum AudioFileDecoder {

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

        while let sample = reader.output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sample) }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }

            let bytes = try copyBytes(from: block)
            let frames = bytes.count / (MemoryLayout<Float>.size * channels)
            guard frames > 0 else { continue }

            // Never silently truncate: if the file turns out longer than the
            // duration-based estimate predicted, grow rather than stop early.
            if written + frames > storage.capacityFrames {
                storage.grow(toAtLeast: written + frames, preserving: written)
            }
            deinterleave(bytes, frames: frames, channels: channels, into: storage, at: written)
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
        return written
    }

    /// Stride-copies channel `c` out of the packed interleaved frame stream.
    /// (Accelerate's `cblas_scopy` is deprecated on this SDK in favour of an
    /// ILP64 interface; a plain loop avoids that churn entirely, and this runs
    /// once per file load, never on the render path.)
    private static func deinterleave(
        _ bytes: [Int8], frames: Int, channels: Int, into storage: AudioStorage, at written: Int
    ) {
        bytes.withUnsafeBytes { raw in
            guard let floats = raw.bindMemory(to: Float.self).baseAddress else { return }
            for c in 0..<channels {
                let dst = storage.pointer(c) + written
                for i in 0..<frames {
                    dst[i] = floats[i * channels + c]
                }
            }
        }
    }

    /// Copies the full logical contents of a `CMBlockBuffer` into a freshly
    /// allocated buffer.
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
    static func copyBytes(from block: CMBlockBuffer) throws -> [Int8] {
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return [] }
        var bytes = [Int8](repeating: 0, count: length)
        let status = bytes.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(
                block, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == noErr else {
            throw DecodeError.unreadable(
                "Could not read decoded audio samples (OSStatus \(status)).")
        }
        return bytes
    }
}
