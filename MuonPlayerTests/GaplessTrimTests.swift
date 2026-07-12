import Foundation
import Testing
@testable import MuonPlayer

/// The fixture is 44,100 frames at 44.1 kHz — 1,000 silent, 41,100 of tone, 2,000 silent
/// — which is what a track whose encoder padding survived into the decode looks like at
/// an album seam. It is already at the canonical rate, so nothing here is blurred by
/// resampling and the counts are exact.
@Suite("Measured gapless trim")
struct GaplessTrimTests {
    static let head = 1_000
    static let tail = 2_000
    static let music = 41_100

    var fixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/trim.wav")
    }

    func decode(_ trim: GaplessTrim) throws -> [Float] {
        let decoder = try FFmpegDecoder(url: fixture, trim: trim)
        var out: [Float] = []
        while let buffer = decoder.nextBuffer() {
            guard let channel = buffer.floatChannelData?[0] else { break }
            out.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        return out
    }

    @Test func decodesTheWholeFileWhenNothingIsTrimmed() throws {
        let frames = try decode(GaplessTrim(head: 0, tail: 0))
        #expect(frames.count == 44_100)
        #expect(abs(frames[0]) < 0.01)              // the silence is still there
        #expect(abs(frames[frames.count - 1]) < 0.01)
    }

    /// The head is skipped and the tail is held back — the latter is the delicate one:
    /// the decoder cannot cap on duration (a file that needs measuring is a file whose
    /// duration is a guess), so it runs a buffer behind and drops what is left at EOF.
    @Test func trimsBothEnds() throws {
        let frames = try decode(GaplessTrim(head: Self.head, tail: Self.tail))
        #expect(frames.count == Self.music)
    }

    /// The point of it: what comes out starts and ends on music, not on silence.
    @Test func leavesNoSilenceAtEitherEnd() throws {
        let frames = try decode(GaplessTrim(head: Self.head, tail: Self.tail))
        let first = frames.prefix(64).map(abs).max() ?? 0
        let last = frames.suffix(64).map(abs).max() ?? 0
        #expect(first > 0.05)
        #expect(last > 0.05)
    }

    /// Seeking is measured from the *content*, so the trimmed head must not shift it.
    @Test func seeksPastTheTrimmedHead() throws {
        let decoder = try FFmpegDecoder(url: fixture, trim: GaplessTrim(head: Self.head, tail: Self.tail))
        decoder.seek(to: 0.5)
        var frames = 0
        while let buffer = decoder.nextBuffer() { frames += Int(buffer.frameLength) }
        let expected = Self.music - Int(0.5 * 44_100)
        #expect(abs(frames - expected) <= 32)
    }

    /// What the maintenance pass would measure on this file, which is what it must store:
    /// the silence, to the sample.
    @Test func measuresTheSilenceItWillLaterTrim() throws {
        let decoder = try EdgeDecoder(path: fixture.path)
        let head = try #require(decoder.head(ms: 500))
        let tail = try #require(decoder.tail(ms: 500))
        #expect(SeamScan.bounds(head).lead == Self.head)
        #expect(SeamScan.bounds(tail).trail == Self.tail)
    }
}
