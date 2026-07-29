#if canImport(AVFoundation)
import AVFoundation
#endif
import Foundation

/// Generates and caches downsampled peak waveforms for tracks, off the main
/// actor. A track is decoded once (via FFmpeg), reduced to a fixed number of
/// normalized peak buckets, and cached in memory for the session.
actor WaveformStore {
    static let shared = WaveformStore()

    /// Number of bars in a generated waveform.
    static let bucketCount = 220

    private var cache: [String: [Float]] = [:]
    private var inFlight: [String: Task<[Float], Never>] = [:]

    /// Return the waveform for `url` (normalized 0...1 peaks), generating it if
    /// needed. Concurrent requests for the same track share one decode.
    func waveform(for url: URL, duration: TimeInterval) async -> [Float] {
        let key = url.path
        if let cached = cache[key] { return cached }
        if let running = inFlight[key] { return await running.value }

        let task = Task<[Float], Never>.detached(priority: .utility) {
            Self.generate(url: url, duration: duration, buckets: Self.bucketCount)
        }
        inFlight[key] = task
        let result = await task.value
        cache[key] = result
        inFlight[key] = nil
        return result
    }

    /// Max-pool `samples` down to at most `count` bars (for the compact mini
    /// player, where the full-resolution waveform would be sub-pixel).
    nonisolated static func downsample(_ samples: [Float], to count: Int) -> [Float] {
        guard samples.count > count, count > 0 else { return samples }
        let group = Double(samples.count) / Double(count)
        return (0..<count).map { i in
            let lo = Int(Double(i) * group)
            let hi = min(samples.count, Int(Double(i + 1) * group))
            return samples[lo..<max(lo + 1, hi)].max() ?? 0
        }
    }

    /// Decode the whole file and reduce it to `buckets` normalized peaks. Samples
    /// are strided within each decoded buffer to keep the pass cheap — peak
    /// envelopes don't need every sample.
    private static func generate(url: URL, duration: TimeInterval, buckets: Int) -> [Float] {
        guard duration > 0, let decoder = try? FFmpegDecoder(url: url) else { return [] }
        let totalFrames = max(1, Int(duration * CanonicalAudio.sampleRate))
        let framesPerBucket = max(1, totalFrames / buckets)
        var peaks = [Float](repeating: 0, count: buckets)
        var framePos = 0
        let stride = 16

        while let buffer = decoder.nextBuffer() {
            let n = Int(buffer.frameLength)
            guard let ch0 = buffer.floatChannelData?[0] else { framePos += n; continue }
            let ch1 = buffer.format.channelCount > 1 ? buffer.floatChannelData?[1] : nil
            var i = 0
            while i < n {
                let bucket = min(buckets - 1, (framePos + i) / framesPerBucket)
                var amp = abs(ch0[i])
                if let ch1 { amp = max(amp, abs(ch1[i])) }
                if amp > peaks[bucket] { peaks[bucket] = amp }
                i += stride
            }
            framePos += n
        }

        // Normalize so the loudest bar is full-height; keep a floor so quiet
        // passages still render a visible sliver.
        let maxPeak = peaks.max() ?? 0
        guard maxPeak > 0 else { return peaks }
        return peaks.map { min(1, max(0.04, $0 / maxPeak)) }
    }
}
