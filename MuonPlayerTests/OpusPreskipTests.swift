import Foundation
import Testing
@testable import MuonPlayer

/// The fixture is one second of 1 kHz tone at 48 kHz, encoded to Opus. Its first 5 ms
/// are loud (0.9) and the rest is quiet (0.15), so a decode that eats the head of the
/// file loses the burst — which is what this is really checking, more than a count.
///
/// Opus carries a 312-sample pre-skip that FFmpeg drops for us, shrinking the first
/// frame but leaving its pts at −312, which it warns it "could not update". Read that
/// pts literally and the priming gets skipped a second time: the first 6.5 ms of every
/// Opus track vanishes, heard as a clipped attack at an album seam. AAC does the same
/// with 64 samples.
@Suite("Opus pre-skip")
struct OpusPreskipTests {
    var fixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/preskip.opus")
    }

    /// Canonical output is 44.1 kHz, so one second of 48 kHz source is 44,100 frames.
    @Test func decodesTheWholeFile() throws {
        let decoder = try FFmpegDecoder(url: fixture)
        var frames = 0
        while let buffer = decoder.nextBuffer() { frames += Int(buffer.frameLength) }
        // Skipping the priming twice would cost 312 input samples — 287 frames here.
        #expect(abs(frames - 44_100) <= 45)
    }

    @Test func keepsTheFirstSamples() throws {
        let decoder = try FFmpegDecoder(url: fixture)
        var head: [Float] = []
        while head.count < 220, let buffer = decoder.nextBuffer() {          // 5 ms
            guard let channel = buffer.floatChannelData?[0] else { break }
            head.append(contentsOf: UnsafeBufferPointer(start: channel,
                                                        count: Int(buffer.frameLength)))
        }
        let peak = head.prefix(220).map(abs).max() ?? 0
        #expect(peak > 0.5)     // the burst is 0.9; without it the tone is only 0.15
    }
}
