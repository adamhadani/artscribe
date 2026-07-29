import Foundation

/// Owns one planar Float32 allocation per channel for the lifetime of a loaded file.
///
/// Deliberately a class with manual memory: the render thread reads these pointers
/// directly and must not trigger ARC or bounds-checking machinery.
///
/// `capacityFrames` can grow (see ``grow(toAtLeast:preserving:)``), which the decoder
/// uses if a file turns out longer than its duration-based estimate predicted — the
/// alternative would be silently truncating the file, which this project never does.
/// Growth only ever happens while a `AudioFileDecoder.decode` call still owns the
/// instance; once handed back inside a `DecodedAudio`, nothing calls `grow` again.
public final class AudioStorage: @unchecked Sendable {
    public let channels: Int
    public private(set) var capacityFrames: Int
    private var buffers: [UnsafeMutablePointer<Float>]

    public init(channels: Int, capacityFrames: Int) {
        precondition(channels > 0 && capacityFrames > 0)
        self.channels = channels
        self.capacityFrames = capacityFrames
        self.buffers = Self.allocate(channels: channels, capacityFrames: capacityFrames)
    }

    deinit {
        Self.deallocate(buffers, capacityFrames: capacityFrames)
    }

    private static func allocate(channels: Int, capacityFrames: Int) -> [UnsafeMutablePointer<
        Float
    >] {
        (0..<channels).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames)
            p.initialize(repeating: 0, count: capacityFrames)
            return p
        }
    }

    private static func deallocate(_ buffers: [UnsafeMutablePointer<Float>], capacityFrames: Int) {
        for b in buffers {
            b.deinitialize(count: capacityFrames)
            b.deallocate()
        }
    }

    public func pointer(_ channel: Int) -> UnsafeMutablePointer<Float> {
        buffers[channel]
    }

    /// Immutable view for the render thread.
    public var channelPointers: [UnsafePointer<Float>] {
        buffers.map { UnsafePointer($0) }
    }

    /// Grows every channel's allocation to at least `minimumFrames`, copying the
    /// first `framesToPreserve` samples of existing data across. No-op if capacity
    /// is already sufficient. Doubles (at minimum) to keep reallocation amortised.
    func grow(toAtLeast minimumFrames: Int, preserving framesToPreserve: Int) {
        guard minimumFrames > capacityFrames else { return }
        precondition(framesToPreserve <= capacityFrames)
        let newCapacity = max(minimumFrames, capacityFrames * 2)
        let newBuffers = Self.allocate(channels: channels, capacityFrames: newCapacity)
        for c in 0..<channels {
            newBuffers[c].update(from: buffers[c], count: framesToPreserve)
        }
        Self.deallocate(buffers, capacityFrames: capacityFrames)
        buffers = newBuffers
        capacityFrames = newCapacity
    }
}
