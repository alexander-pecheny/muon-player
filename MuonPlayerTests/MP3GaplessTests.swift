import Foundation
import Testing
@testable import MuonPlayer

/// MPEG1 Layer III, 44.1 kHz, stereo, 128 kbps — 417 bytes a frame, 1152 samples.
private let frameSize = 417
private func mpegFrame(_ fill: UInt8) -> Data {
    var d = Data([0xFF, 0xFB, 0x90, 0x00])
    d.append(Data(repeating: fill, count: frameSize - 4))
    return d
}

private func mp3(frames: Int) -> Data {
    var d = Data()
    for i in 0 ..< frames { d.append(mpegFrame(UInt8(i % 251 + 1))) }
    return d
}

@Suite("TagWriter — MP3 gapless")
struct MP3GaplessTests {
    private func roundTrip(_ file: Data, delay: Int, padding: Int) throws -> (Data, TagWriter.MP3Gapless?) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp3")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try TagWriter.writeMP3Gapless(delay: delay, padding: padding, to: url)
        let out = try Data(contentsOf: url)
        return (out, TagWriter.readMP3Gapless(out))
    }

    @Test("a file with no Xing header gets one, and keeps every audio frame")
    func addsHeader() throws {
        let original = mp3(frames: 10)
        #expect(TagWriter.readMP3Gapless(original) == nil)

        let (out, tag) = try roundTrip(original, delay: 576, padding: 1234)
        #expect(tag == TagWriter.MP3Gapless(delay: 576, padding: 1234, frames: 10))

        // The header frame is prepended; the audio behind it is untouched.
        let headerFrameSize = out.count - original.count
        #expect(out.suffix(original.count) == original)
        #expect(headerFrameSize > 0)
    }

    /// The case that matters for a library: a header is already there and lying — the
    /// values are replaced, and no second header is stacked in front of the first.
    @Test("an existing header is corrected in place, not duplicated")
    func correctsExistingHeader() throws {
        let (once, _) = try roundTrip(mp3(frames: 10), delay: 0, padding: 0)
        #expect(TagWriter.readMP3Gapless(once)?.delay == 0)

        let (twice, tag) = try roundTrip(once, delay: 576, padding: 1234)
        #expect(tag == TagWriter.MP3Gapless(delay: 576, padding: 1234, frames: 10))
        #expect(twice.count == once.count)          // replaced, not stacked
    }

    @Test("an ID3 tag in front of the audio survives")
    func keepsID3() throws {
        var file = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0A])  // ID3v2.4, 10 bytes
        file.append(Data(repeating: 0, count: 10))
        file.append(mp3(frames: 4))

        let (out, tag) = try roundTrip(file, delay: 1000, padding: 2000)
        #expect(tag == TagWriter.MP3Gapless(delay: 1000, padding: 2000, frames: 4))
        #expect(out.prefix(20) == file.prefix(20))
    }

    @Test("the 12-bit fields are respected")
    func rejectsOversizedValues() {
        #expect(TagWriter.MP3Gapless(delay: 576, padding: 1234, frames: 1).fitsInTag)
        #expect(!TagWriter.MP3Gapless(delay: 4096, padding: 0, frames: 1).fitsInTag)
        #expect(!TagWriter.MP3Gapless(delay: 0, padding: -1, frames: 1).fitsInTag)
    }
}
