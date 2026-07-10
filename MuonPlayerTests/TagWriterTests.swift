import Testing
import Foundation
@testable import MuonPlayer

/// Minimal Ogg page reader/writer, independent of TagWriter's own, so the test
/// can't pass by agreeing with a broken implementation.
private struct OggPage {
    var flags: UInt8
    var seq: UInt32
    var segTable: [UInt8]
    var body: Data

    /// Packets ending in this page (a segment < 255 terminates one).
    var packets: [Data] {
        var out: [Data] = []
        var buf = Data(), p = body.startIndex
        for seg in segTable {
            buf.append(body[p ..< p + Int(seg)]); p += Int(seg)
            if seg < 255 { out.append(buf); buf = Data() }
        }
        return out
    }
}

private func parsePages(_ d: Data) -> [OggPage] {
    var pages: [OggPage] = []
    var i = d.startIndex
    while i + 27 <= d.endIndex, d[i ..< i + 4].elementsEqual("OggS".utf8) {
        let nsegs = Int(d[i + 26])
        let segs = Array(d[i + 27 ..< i + 27 + nsegs])
        let len = segs.reduce(0) { $0 + Int($1) }
        let start = i + 27 + nsegs
        let seq = (0..<4).reduce(UInt32(0)) { $0 | UInt32(d[i + 18 + $1]) << (8 * UInt32($1)) }
        pages.append(OggPage(flags: d[i + 5], seq: seq, segTable: segs,
                             body: d.subdata(in: start ..< start + len)))
        i = start + len
    }
    return pages
}

private func buildPage(flags: UInt8, serial: UInt32, seq: UInt32, packet: Data) -> Data {
    var segs: [UInt8] = []
    var l = packet.count
    while l >= 255 { segs.append(255); l -= 255 }
    segs.append(UInt8(l))
    var p = Data("OggS".utf8)
    p.append(0); p.append(flags)
    p.append(contentsOf: [UInt8](repeating: 0, count: 8))          // granule
    p.append(contentsOf: (0..<4).map { UInt8((serial >> (8 * $0)) & 0xFF) })
    p.append(contentsOf: (0..<4).map { UInt8((seq >> (8 * $0)) & 0xFF) })
    p.append(contentsOf: [0, 0, 0, 0])                             // CRC (not verified on read)
    p.append(UInt8(segs.count)); p.append(contentsOf: segs); p.append(packet)
    return p
}

private func vorbisComments(_ payload: Data) -> [String] {
    var i = payload.startIndex
    func u32() -> Int {
        defer { i += 4 }
        return (0..<4).reduce(0) { $0 | Int(payload[i + $1]) << (8 * $1) }
    }
    i += u32()                                    // skip vendor
    return (0..<u32()).compactMap { _ in
        let n = u32()
        defer { i += n }
        return String(bytes: payload[i ..< i + n], encoding: .utf8)
    }
}

private func opusFixture() -> Data {
    var head = Data("OpusHead".utf8)
    head.append(contentsOf: [1, 2, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0])   // v1, 2ch, 48k

    var comments = Data()
    func appendLE(_ n: Int) { comments.append(contentsOf: (0..<4).map { UInt8((n >> (8 * $0)) & 0xFF) }) }
    let fields = ["TITLE=Old", "ARTIST=A", "ALBUM=Alb", "UNSYNCEDLYRICS=keep\nme"]
    let vendor = Data("test".utf8)
    appendLE(vendor.count); comments.append(vendor)
    appendLE(fields.count)
    for f in fields { let d = Data(f.utf8); appendLE(d.count); comments.append(d) }
    var tags = Data("OpusTags".utf8); tags.append(comments)

    let audio = Data((0..<600).map { UInt8($0 & 0xFF) })            // spans two lacing values
    var out = buildPage(flags: 0x02, serial: 7, seq: 0, packet: head)
    out.append(buildPage(flags: 0, serial: 7, seq: 1, packet: tags))
    out.append(buildPage(flags: 0x04, serial: 7, seq: 2, packet: audio))
    return out
}

@Suite("TagWriter — Ogg")
struct TagWriterOggTests {
    private func writeFixture(_ edits: TagEdits) throws -> [OggPage] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".opus")
        try opusFixture().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try TagWriter.write(edits, to: url)
        return parsePages(try Data(contentsOf: url))
    }

    /// A second packet on the BOS page is read as another OpusHead by any
    /// demuxer, which rejects the stream — the file loses every tag at once.
    @Test("identification header stays alone on the BOS page")
    func idHeaderAlone() throws {
        let pages = try writeFixture(TagEdits(title: "New"))
        #expect(pages[0].flags & 0x02 != 0)
        #expect(pages[0].packets.count == 1)
        #expect(pages[0].body.prefix(8).elementsEqual("OpusHead".utf8))
        #expect(pages[1].body.prefix(8).elementsEqual("OpusTags".utf8))
    }

    @Test("edited field replaces, untouched fields survive")
    func commentsPreserved() throws {
        let pages = try writeFixture(TagEdits(title: "New"))
        let comments = vorbisComments(pages[1].packets[0].dropFirst(8))
        #expect(comments.contains("TITLE=New"))
        #expect(!comments.contains("TITLE=Old"))
        #expect(comments.contains("ARTIST=A"))
        #expect(comments.contains("ALBUM=Alb"))
        #expect(comments.contains("UNSYNCEDLYRICS=keep\nme"))
    }

    @Test("audio pages keep their bytes, flags and page order")
    func audioIntact() throws {
        let pages = try writeFixture(TagEdits(title: "New"))
        let audio = pages.last!
        #expect(pages.count == 3)
        #expect(audio.flags & 0x04 != 0)                            // EOS
        #expect(audio.seq == 2)
        #expect(audio.body.elementsEqual((0..<600).map { UInt8($0 & 0xFF) }))
        #expect(zip(pages, 0...).allSatisfy { $0.seq == UInt32($1) })
    }
}

/// The extension does not decide the writer — `.aac` is raw ADTS about as often
/// as it is MP4, and `.m4a` occasionally holds ADTS.
@Suite("TagWriter — container dispatch")
struct TagWriterDispatchTests {
    private func write(_ bytes: Data, ext: String) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try TagWriter.write(TagEdits(title: "New"), to: url)
        return try Data(contentsOf: url)
    }

    /// One silent ADTS frame: sync 0xFFF, AAC-LC, 44.1kHz, stereo.
    private var adts: Data {
        var d = Data([0xFF, 0xF1, 0x50, 0x80, 0x01, 0xFF, 0xFC])
        d.append(Data(repeating: 0x21, count: 25))
        return d
    }

    @Test("raw ADTS gets a prepended ID3v2 tag, audio untouched")
    func adtsTakesID3() throws {
        let out = try write(adts, ext: "aac")
        #expect(out.prefix(3).elementsEqual("ID3".utf8))
        #expect(out.suffix(adts.count).elementsEqual(adts))
    }

    @Test("ADTS misnamed .m4a still routes to ID3 rather than failing")
    func adtsNamedM4A() throws {
        #expect(try write(adts, ext: "m4a").prefix(3).elementsEqual("ID3".utf8))
    }

    @Test("an unrecognised container is refused, whatever it is named")
    func refusesUnknownContainer() {
        let junk = Data("NOTAUDIO".utf8) + Data(repeating: 0x7F, count: 32)
        #expect(throws: TagWriter.TagError.self) { try write(junk, ext: "mp3") }
        #expect(throws: TagWriter.TagError.self) { try write(junk, ext: "flac") }
    }

    /// Matroska, ASF and CAF hold tags we cannot write, so they are neither
    /// indexed nor editable — see `AudioFormat.supportedExtensions`.
    @Test("an extension we never tag is refused even with editable content")
    func refusesUneditableExtension() {
        #expect(throws: TagWriter.TagError.self) { try write(adts, ext: "mka") }
        #expect(throws: TagWriter.TagError.self) { try write(adts, ext: "caf") }
    }

    /// The content wins: a genuine RIFF/WAVE named `.mp3` is edited as a WAV.
    @Test("a misnamed but recognisable container edits as its real format")
    func dispatchesOnContent() throws {
        var riff = Data("RIFF".utf8)
        let body = Data("WAVE".utf8) + Data("data".utf8) + Data([4, 0, 0, 0]) + Data([1, 2, 3, 4])
        riff.append(contentsOf: [UInt8(body.count), 0, 0, 0])
        riff.append(body)
        let out = try write(riff, ext: "mp3")
        #expect(out.prefix(4).elementsEqual("RIFF".utf8))
    }
}

// MARK: - APEv2

private func apeFixture(id3v1: Data? = nil) -> Data {
    var d = Data("wvpk".utf8)                              // WavPack magic
    d.append(Data(repeating: 0x11, count: 64))             // stand-in audio
    if let id3v1 { d.append(id3v1) }
    return d
}

private func id3v1(title: String, comment: String, track: UInt8?) -> Data {
    var t = Data(repeating: 0, count: 128)
    t.replaceSubrange(0..<3, with: Data("TAG".utf8))
    t.replaceSubrange(3..<(3 + title.count), with: Data(title.utf8))
    t.replaceSubrange(97..<(97 + comment.count), with: Data(comment.utf8))
    if let track { t[125] = 0; t[126] = track }
    return t
}

/// Items are `[size LE][flags LE]key\0value`, between a header and footer.
private func apeItems(_ file: Data) -> [String: String] {
    guard file.count >= 32,
          file.suffix(32).prefix(8).elementsEqual("APETAGEX".utf8) else { return [:] }
    let footer = file.count - 32
    let size = (0..<4).reduce(0) { $0 | Int(file[footer + 12 + $1]) << (8 * $1) }
    var i = file.count - size, out: [String: String] = [:]
    while i + 8 < footer {
        let vlen = (0..<4).reduce(0) { $0 | Int(file[i + $1]) << (8 * $1) }
        i += 8
        guard let nul = file[i ..< footer].firstIndex(of: 0) else { break }
        let key = String(bytes: file[i ..< nul], encoding: .utf8) ?? ""
        i = nul + 1
        guard i + vlen <= footer else { break }
        out[key] = String(bytes: file[i ..< i + vlen], encoding: .utf8)
        i += vlen
    }
    return out
}

@Suite("TagWriter — APEv2")
struct TagWriterAPETests {
    private func write(_ fixture: Data, _ edits: TagEdits) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wv")
        try fixture.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try TagWriter.write(edits, to: url)
        return try Data(contentsOf: url)
    }

    @Test("tag is appended with a header and a footer, audio untouched")
    func appendsTag() throws {
        let out = try write(apeFixture(), TagEdits(title: "T", albumArtist: "AA"))
        #expect(out.prefix(68).elementsEqual(apeFixture()))
        #expect(out.suffix(32).prefix(8).elementsEqual("APETAGEX".utf8))
        #expect(out.dropFirst(68).prefix(8).elementsEqual("APETAGEX".utf8))
        #expect(apeItems(out) == ["Title": "T", "Album Artist": "AA"])
    }

    @Test("re-editing replaces the tag rather than stacking another one")
    func replacesTag() throws {
        let once = try write(apeFixture(), TagEdits(title: "One"))
        let twice = try write(once, TagEdits(title: "Two"))
        #expect(apeItems(twice) == ["Title": "Two"])
        #expect(once.count == twice.count)
    }

    /// FFmpeg finds the APE footer only at the exact end of file, so an ID3v1
    /// block left behind it would hide every tag we just wrote.
    @Test("a trailing ID3v1 is absorbed and dropped, not preserved")
    func absorbsID3v1() throws {
        let fixture = apeFixture(id3v1: id3v1(title: "Stale", comment: "Legacy", track: 9))
        let out = try write(fixture, TagEdits(title: "New"))
        #expect(!out.suffix(128).prefix(3).elementsEqual("TAG".utf8))
        #expect(out.suffix(32).prefix(8).elementsEqual("APETAGEX".utf8))
        let items = apeItems(out)
        #expect(items["Title"] == "New")          // the edit beats the legacy value
        #expect(items["Comment"] == "Legacy")     // …but nothing else is lost
        #expect(items["Track"] == "9")
    }
}

// MARK: - RIFF / AIFF

@Suite("TagWriter — WAV and AIFF")
struct TagWriterIFFTests {
    private func chunks(_ file: Data, bigEndian: Bool) -> [(String, Data)] {
        var out: [(String, Data)] = []
        var i = 12
        while i + 8 <= file.count {
            let id = String(bytes: file[i ..< i + 4], encoding: .isoLatin1) ?? ""
            let b = (0..<4).map { Int(file[i + 4 + $0]) }
            let size = bigEndian ? b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]
                                 : b[3] << 24 | b[2] << 16 | b[1] << 8 | b[0]
            guard size >= 0, i + 8 + size <= file.count else { break }
            out.append((id, file.subdata(in: i + 8 ..< i + 8 + size)))
            i += 8 + size + (size & 1)
        }
        return out
    }

    /// `NAME` is odd-length on purpose: IFF pads chunks to an even boundary and
    /// the pad byte must not be counted in the chunk size.
    private func aiff() -> Data {
        var d = Data("FORM".utf8)
        var body = Data("AIFF".utf8)
        body.append(Data("NAME".utf8)); body.append(contentsOf: [0, 0, 0, 3])
        body.append(Data("Old".utf8)); body.append(0)                    // pad
        body.append(Data("SSND".utf8)); body.append(contentsOf: [0, 0, 0, 4])
        body.append(Data([1, 2, 3, 4]))
        d.append(contentsOf: [UInt8(body.count >> 24), UInt8((body.count >> 16) & 0xFF),
                              UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)])
        d.append(body)
        return d
    }

    private func wav() -> Data {
        var d = Data("RIFF".utf8)
        var body = Data("WAVE".utf8)
        body.append(Data("data".utf8)); body.append(contentsOf: [4, 0, 0, 0])
        body.append(Data([1, 2, 3, 4]))
        d.append(contentsOf: [UInt8(body.count & 0xFF), UInt8((body.count >> 8) & 0xFF),
                              UInt8((body.count >> 16) & 0xFF), UInt8(body.count >> 24)])
        d.append(body)
        return d
    }

    private func write(_ fixture: Data, ext: String, _ edits: TagEdits) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        try fixture.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try TagWriter.write(edits, to: url)
        return try Data(contentsOf: url)
    }

    @Test("WAV gets an id3 chunk, audio chunk survives, RIFF size is fixed up")
    func wavWrites() throws {
        let out = try write(wav(), ext: "wav", TagEdits(title: "New", albumArtist: "AA"))
        let cs = chunks(out, bigEndian: false)
        #expect(cs.first { $0.0 == "data" }?.1.elementsEqual([1, 2, 3, 4]) == true)
        #expect(cs.first { $0.0 == "id3 " }?.1.prefix(3).elementsEqual("ID3".utf8) == true)
        let declared = (0..<4).reduce(0) { $0 | Int(out[4 + $1]) << (8 * $1) }
        #expect(declared == out.count - 8)
    }

    /// FFmpeg reads both the native chunk and the ID3 chunk, and the native one
    /// wins a duplicate key — so a stale NAME would outrank the new title.
    @Test("AIFF keeps NAME in step with the ID3 chunk, and pads odd chunks")
    func aiffWrites() throws {
        let out = try write(aiff(), ext: "aiff", TagEdits(title: "New", artist: "A"))
        let cs = chunks(out, bigEndian: true)
        #expect(cs.first { $0.0 == "NAME" }?.1.elementsEqual("New".utf8) == true)
        #expect(cs.first { $0.0 == "AUTH" }?.1.elementsEqual("A".utf8) == true)
        #expect(cs.first { $0.0 == "SSND" }?.1.elementsEqual([1, 2, 3, 4]) == true)
        #expect(cs.first { $0.0 == "ID3 " } != nil)
        let declared = (0..<4).reduce(0) { ($0 << 8) | Int(out[4 + $1]) }
        #expect(declared == out.count - 8)
    }

    @Test("re-editing rewrites chunks in place rather than appending duplicates")
    func iffIdempotent() throws {
        let once = try write(wav(), ext: "wav", TagEdits(title: "One"))
        let twice = try write(once, ext: "wav", TagEdits(title: "One"))
        #expect(once.count == twice.count)
        #expect(chunks(twice, bigEndian: false).filter { $0.0 == "id3 " }.count == 1)
    }
}
