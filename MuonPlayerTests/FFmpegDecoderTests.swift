import Foundation
import Testing
@testable import MuonPlayer

/// The fixture is a 44,877-sample tone — deliberately not a whole number of
/// 1024-sample AAC frames, so the encoder had to pad the last one. It carries an
/// edit list and no `iTunSMPB`, which is what most of the m4a rips in a real
/// library look like.
@Suite("FFmpegDecoder gapless trim")
struct FFmpegDecoderTests {
    static let sourceSamples = 44_877

    var fixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/edit-list.m4a")
    }

    func decodedFrames(_ url: URL) throws -> Int {
        let decoder = try FFmpegDecoder(url: url)
        var total = 0
        while let buffer = decoder.nextBuffer() { total += Int(buffer.frameLength) }
        return total
    }

    /// FFmpeg drops the priming for an edit-list mp4 and reports the true duration,
    /// but goes right on decoding the trailing padding — 179 samples of it here, and
    /// 25 ms of it in a real rip, heard as a gap at every seam of a gapless album.
    /// We stop at the declared length ourselves.
    ///
    /// An edit list is written in the movie timescale (milliseconds), so it can only
    /// place the end to within ~1 ms — hence the tolerance. `iTunSMPB`, which is
    /// sample-exact, is preferred over it wherever a file carries one.
    @Test func trimsTrailingPaddingOfEditListMP4() throws {
        let frames = try decodedFrames(fixture)
        let oneMillisecond = 45
        #expect(abs(frames - Self.sourceSamples) <= oneMillisecond)
    }

    @Test func reportsContentDuration() throws {
        let decoder = try FFmpegDecoder(url: fixture)
        #expect(abs(decoder.duration - Double(Self.sourceSamples) / 44_100) < 0.002)
    }
}
