#if os(Android)
import Foundation

// The decode path speaks AVFoundation's PCM vocabulary: a fixed float32
// non-interleaved stereo format, and buffers that carry a capacity, a mutable
// frameLength and per-channel plane pointers. Nothing else of AVFoundation
// reaches this far down, so Android gets that vocabulary rather than a port of
// every call site.

public typealias AVAudioFramePosition = Int64
public typealias AVAudioFrameCount = UInt32
public typealias AVAudioChannelCount = UInt32

public enum AVAudioCommonFormat { case pcmFormatFloat32 }

public final class AVAudioFormat: @unchecked Sendable {
    public let sampleRate: Double
    public let channelCount: AVAudioChannelCount
    public let commonFormat: AVAudioCommonFormat
    public let isInterleaved: Bool

    public init?(commonFormat: AVAudioCommonFormat, sampleRate: Double,
                 channels: AVAudioChannelCount, interleaved: Bool) {
        guard sampleRate > 0, channels > 0 else { return nil }
        self.commonFormat = commonFormat
        self.sampleRate = sampleRate
        self.channelCount = channels
        self.isInterleaved = interleaved
    }
}

/// One malloc'd float plane per channel, freed with the buffer. `frameLength` is
/// what the consumer reads; `frameCapacity` is what was allocated, and swr_convert
/// is never handed more than that.
public final class AVAudioPCMBuffer {
    public let format: AVAudioFormat
    public let frameCapacity: AVAudioFrameCount
    public var frameLength: AVAudioFrameCount = 0

    private let planes: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let planeCount: Int

    public init?(pcmFormat: AVAudioFormat, frameCapacity: AVAudioFrameCount) {
        guard frameCapacity > 0 else { return nil }
        self.format = pcmFormat
        self.frameCapacity = frameCapacity
        self.planeCount = Int(pcmFormat.channelCount)
        self.planes = .allocate(capacity: planeCount)
        for ch in 0..<planeCount {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Int(frameCapacity))
            p.initialize(repeating: 0, count: Int(frameCapacity))
            planes[ch] = p
        }
    }

    deinit {
        for ch in 0..<planeCount { planes[ch].deallocate() }
        planes.deallocate()
    }

    public var floatChannelData: UnsafePointer<UnsafeMutablePointer<Float>>? {
        UnsafePointer(planes)
    }
}
#endif
