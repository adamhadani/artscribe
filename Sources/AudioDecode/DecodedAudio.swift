import ArtscribeKit

/// A fully decoded file. Immutable once built; both the UI and the render thread read it.
public struct DecodedAudio: @unchecked Sendable {
    public let channels: Int
    public let sampleRate: Double
    public let frameCount: FrameIndex
    public let storage: AudioStorage

    public init(channels: Int, sampleRate: Double, frameCount: FrameIndex, storage: AudioStorage) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.storage = storage
    }

    public func channel(_ index: Int) -> UnsafePointer<Float> {
        UnsafePointer(storage.pointer(index))
    }

    public var duration: Double { Double(frameCount) / sampleRate }
}
