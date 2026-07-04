import Foundation

/// In-place metadata writer — edits tags directly in the source files without
/// re-encoding audio (the mutagen approach), so it stays fast and lossless.
/// Supports MP4/M4A (iTunes `ilst` atoms), MP3 (ID3v2.4) and FLAC (Vorbis
/// comments). Only the fields present in `TagEdits` are changed; every other
/// tag, and the audio itself, is preserved byte-for-byte.
enum TagWriter {
    enum TagError: Error, CustomStringConvertible {
        case unsupportedFormat(String)
        case malformed(String)
        var description: String {
            switch self {
            case .unsupportedFormat(let e): return "Tag editing isn't supported for .\(e) files yet."
            case .malformed(let m): return "Couldn't parse the file: \(m)"
            }
        }
    }

    static func write(_ edits: TagEdits, to url: URL) throws {
        let ext = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let out: Data
        switch ext {
        case "m4a", "mp4", "aac", "alac", "m4b":
            out = try MP4.write(edits, into: data)
        case "mp3":
            out = try ID3.write(edits, into: data)
        case "flac":
            out = try FLAC.write(edits, into: data)
        case "ogg", "oga", "opus":
            out = try Ogg.write(edits, into: data)
        default:
            throw TagError.unsupportedFormat(ext)
        }
        try writeAtomically(out, to: url)
    }

    /// Whether this file type can currently be edited.
    static func isSupported(_ url: URL) -> Bool {
        ["m4a", "mp4", "aac", "alac", "m4b", "mp3", "flac", "ogg", "oga", "opus"].contains(url.pathExtension.lowercased())
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".muon-tag-" + UUID().uuidString + "." + url.pathExtension)
        try data.write(to: tmp, options: .atomic)
        // Preserve nothing else; swap into place.
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}

// MARK: - Big-endian helpers

private extension FixedWidthInteger {
    var beBytes: [UInt8] {
        withUnsafeBytes(of: bigEndian) { Array($0) }
    }
}

private extension Data {
    func beUInt32(_ offset: Int) -> UInt32 {
        UInt32(self[startIndex + offset]) << 24 | UInt32(self[startIndex + offset + 1]) << 16
        | UInt32(self[startIndex + offset + 2]) << 8 | UInt32(self[startIndex + offset + 3])
    }
}

// MARK: - MP4 / M4A (iTunes ilst atoms)

private enum MP4 {
    /// Container atoms whose payloads are themselves atoms (the path to `ilst`).
    static let containers: Set<String> = ["moov", "trak", "edts", "mdia", "minf", "stbl", "udta", "meta", "ilst"]

    final class Box {
        var type: String
        var children: [Box]?      // non-nil for container atoms
        var payload: Data         // leaf bytes (containers ignore this)
        var metaPrefix: Data?     // `meta`'s 4-byte version/flags

        init(type: String, children: [Box]? = nil, payload: Data = Data(), metaPrefix: Data? = nil) {
            self.type = type; self.children = children; self.payload = payload; self.metaPrefix = metaPrefix
        }
    }

    // Field → iTunes atom type.
    static let key: [String: String] = [
        "title": "\u{A9}nam", "artist": "\u{A9}ART", "album": "\u{A9}alb",
        "albumArtist": "aART", "composer": "\u{A9}wrt",
    ]

    static func write(_ edits: TagEdits, into file: Data) throws -> Data {
        // Locate top-level moov + mdat.
        let top = try scanTopLevel(file)
        guard let moov = top.first(where: { $0.type == "moov" }) else {
            throw TagWriter.TagError.malformed("no moov atom")
        }
        let mdatStart = top.first(where: { $0.type == "mdat" })?.offset

        let moovData = file.subdata(in: moov.offset ..< moov.offset + moov.size)
        let moovBox = parse(moovData)[0]

        applyEdits(edits, to: moovBox)

        var newMoov = serialize(moovBox)
        let delta = newMoov.count - moovData.count
        // If moov precedes mdat, the media chunks shift — fix stco/co64 offsets.
        if delta != 0, let mdatStart, moov.offset < mdatStart {
            patchChunkOffsets(moovBox, delta: Int64(delta))
            newMoov = serialize(moovBox)
        }

        var out = Data()
        out.append(file.subdata(in: file.startIndex ..< moov.offset))
        out.append(newMoov)
        out.append(file.subdata(in: (moov.offset + moov.size) ..< file.endIndex))
        return out
    }

    private static func applyEdits(_ edits: TagEdits, to moov: Box) {
        let ilst = ensureILST(moov)
        func setText(_ field: String, _ value: String?) {
            guard let value, let atom = key[field] else { return }
            replaceItem(in: ilst, type: atom, dataPayload: textData(value))
        }
        setText("title", edits.title)
        setText("artist", edits.artist)
        setText("album", edits.album)
        setText("albumArtist", edits.albumArtist)
        setText("composer", edits.composer)
        if let trk = edits.trackNo {
            replaceItem(in: ilst, type: "trkn", dataPayload: trackData(trk))
        }
    }

    /// UTF-8 `data` atom payload: type-indicator 1 (text) + 4-byte locale + text.
    private static func textData(_ s: String) -> Data {
        var d = Data()
        d.append(contentsOf: UInt32(1).beBytes)
        d.append(contentsOf: UInt32(0).beBytes)
        d.append(s.data(using: .utf8) ?? Data())
        return d
    }

    /// `trkn` binary payload: type-indicator 0 + locale + [00 00, track, total, 00 00].
    private static func trackData(_ n: Int) -> Data {
        var d = Data()
        d.append(contentsOf: UInt32(0).beBytes)
        d.append(contentsOf: UInt32(0).beBytes)
        d.append(contentsOf: [0, 0])
        d.append(contentsOf: UInt16(clamping: n).beBytes)
        d.append(contentsOf: [0, 0, 0, 0])
        return d
    }

    /// Replace (or add) an ilst item wrapping a single `data` atom.
    private static func replaceItem(in ilst: Box, type: String, dataPayload: Data) {
        ilst.children?.removeAll { $0.type == type }
        let dataBox = Box(type: "data", payload: dataPayload)
        ilst.children?.append(Box(type: type, children: [dataBox]))
    }

    private static func ensureILST(_ moov: Box) -> Box {
        let udta = child(moov, "udta") ?? {
            let b = Box(type: "udta", children: []); moov.children?.append(b); return b
        }()
        let meta = child(udta, "meta") ?? {
            let b = Box(type: "meta", children: [hdlrBox()], metaPrefix: Data([0, 0, 0, 0]))
            udta.children?.append(b); return b
        }()
        if meta.metaPrefix == nil { meta.metaPrefix = Data([0, 0, 0, 0]) }
        return child(meta, "ilst") ?? {
            let b = Box(type: "ilst", children: []); meta.children?.append(b); return b
        }()
    }

    private static func hdlrBox() -> Box {
        var p = Data()
        p.append(contentsOf: [0, 0, 0, 0])              // version/flags
        p.append(contentsOf: [0, 0, 0, 0])              // predefined
        p.append("mdir".data(using: .ascii)!)           // handler type
        p.append("appl".data(using: .ascii)!)           // manufacturer
        p.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0, 0]) // reserved + null name
        return Box(type: "hdlr", payload: p)
    }

    private static func child(_ box: Box, _ type: String) -> Box? {
        box.children?.first { $0.type == type }
    }

    private static func patchChunkOffsets(_ box: Box, delta: Int64) {
        if box.type == "stco" { patchSTCO(box, delta: delta, wide: false) }
        else if box.type == "co64" { patchSTCO(box, delta: delta, wide: true) }
        box.children?.forEach { patchChunkOffsets($0, delta: delta) }
    }

    private static func patchSTCO(_ box: Box, delta: Int64, wide: Bool) {
        var p = box.payload
        guard p.count >= 8 else { return }
        let count = Int(p.beUInt32(4))
        let entrySize = wide ? 8 : 4
        var idx = 8
        for _ in 0..<count {
            guard idx + entrySize <= p.count else { break }
            if wide {
                var v = UInt64(0)
                for k in 0..<8 { v = v << 8 | UInt64(p[p.startIndex + idx + k]) }
                v = UInt64(Int64(v) + delta)
                for k in 0..<8 { p[p.startIndex + idx + k] = UInt8((v >> (8 * (7 - k))) & 0xFF) }
            } else {
                let v = UInt32(Int64(p.beUInt32(idx)) + delta)
                let b = v.beBytes
                for k in 0..<4 { p[p.startIndex + idx + k] = b[k] }
            }
            idx += entrySize
        }
        box.payload = p
    }

    // MARK: MP4 parse / serialize

    struct TopBox { let type: String; let offset: Int; let size: Int }

    static func scanTopLevel(_ data: Data) throws -> [TopBox] {
        var boxes: [TopBox] = []
        var i = data.startIndex
        while i + 8 <= data.endIndex {
            let size32 = Int(data.beUInt32(i - data.startIndex))
            let type = str(data, i + 4)
            var size = size32
            if size32 == 1 {
                guard i + 16 <= data.endIndex else { break }
                var v = UInt64(0)
                for k in 0..<8 { v = v << 8 | UInt64(data[i + 8 + k]) }
                size = Int(v)
            } else if size32 == 0 {
                size = data.endIndex - i
            }
            guard size >= 8, i + size <= data.endIndex else { break }
            boxes.append(TopBox(type: type, offset: i, size: size))
            i += size
        }
        return boxes
    }

    static func parse(_ data: Data) -> [Box] {
        var boxes: [Box] = []
        var i = data.startIndex
        while i + 8 <= data.endIndex {
            let size32 = Int(data.beUInt32(i - data.startIndex))
            let type = str(data, i + 4)
            var headerLen = 8
            var size = size32
            if size32 == 1 {
                guard i + 16 <= data.endIndex else { break }
                var v = UInt64(0)
                for k in 0..<8 { v = v << 8 | UInt64(data[i + 8 + k]) }
                size = Int(v); headerLen = 16
            } else if size32 == 0 {
                size = data.endIndex - i
            }
            guard size >= headerLen, i + size <= data.endIndex else { break }
            let payload = data.subdata(in: (i + headerLen) ..< (i + size))
            if containers.contains(type) {
                if type == "meta", payload.count >= 4 {
                    let prefix = payload.subdata(in: payload.startIndex ..< payload.startIndex + 4)
                    let rest = payload.subdata(in: payload.startIndex + 4 ..< payload.endIndex)
                    boxes.append(Box(type: type, children: parse(rest), metaPrefix: prefix))
                } else {
                    boxes.append(Box(type: type, children: parse(payload)))
                }
            } else {
                boxes.append(Box(type: type, payload: payload))
            }
            i += size
        }
        return boxes
    }

    static func serialize(_ box: Box) -> Data {
        var body = Data()
        if let children = box.children {
            if let prefix = box.metaPrefix { body.append(prefix) }
            for c in children { body.append(serialize(c)) }
        } else {
            body = box.payload
        }
        var out = Data()
        out.append(contentsOf: UInt32(body.count + 8).beBytes)
        out.append(box.type.data(using: .isoLatin1) ?? Data([0, 0, 0, 0]))
        out.append(body)
        return out
    }

    private static func str(_ data: Data, _ offset: Int) -> String {
        String(bytes: data[offset ..< offset + 4], encoding: .isoLatin1) ?? "????"
    }
}

// MARK: - MP3 (ID3v2.4)

private enum ID3 {
    struct Frame { var id: String; var content: Data }

    static func write(_ edits: TagEdits, into file: Data) throws -> Data {
        var frames: [Frame] = []
        var audioStart = file.startIndex

        // Existing ID3v2 tag? The 10-byte header size is syncsafe in every
        // version; per-frame sizes are plain uint32 in v2.3 but syncsafe in v2.4.
        if file.count > 10, str(file, 0, 3) == "ID3" {
            let major = file[file.startIndex + 3]
            let size = syncsafe(file, 6)
            audioStart = min(file.startIndex + 10 + size, file.endIndex)
            parseFrames(file, from: file.startIndex + 10, to: audioStart,
                        syncsafeFrames: major >= 4, into: &frames)
        }

        // Apply edits (empty string clears the frame). Only non-nil fields.
        set(&frames, "TIT2", edits.title)
        set(&frames, "TPE1", edits.artist)
        set(&frames, "TALB", edits.album)
        set(&frames, "TPE2", edits.albumArtist)
        set(&frames, "TCOM", edits.composer)
        if let trk = edits.trackNo { set(&frames, "TRCK", String(trk)) }

        // Emit as a clean ID3v2.4 tag (syncsafe frame sizes, UTF-8 for edits;
        // preserved frames keep their own encoding byte and content).
        var body = Data()
        for f in frames where !f.content.isEmpty {
            body.append(f.id.data(using: .ascii) ?? Data([0, 0, 0, 0]))
            body.append(contentsOf: encodeSyncsafe(f.content.count))
            body.append(contentsOf: [0, 0])               // flags
            body.append(f.content)
        }
        var tag = Data()
        tag.append("ID3".data(using: .ascii)!)
        tag.append(contentsOf: [4, 0, 0])                 // v2.4.0, no flags
        tag.append(contentsOf: encodeSyncsafe(body.count))
        tag.append(body)

        var out = Data()
        out.append(tag)
        out.append(file.subdata(in: audioStart ..< file.endIndex))
        return out
    }

    private static func set(_ frames: inout [Frame], _ id: String, _ value: String?) {
        guard let value else { return }
        frames.removeAll { $0.id == id }
        var content = Data([3])                            // UTF-8 encoding
        content.append(value.data(using: .utf8) ?? Data())
        frames.append(Frame(id: id, content: content))
    }

    private static func parseFrames(_ data: Data, from: Int, to: Int,
                                    syncsafeFrames: Bool, into frames: inout [Frame]) {
        var i = from
        while i + 10 <= to {
            let id = str(data, i - data.startIndex, 4)
            // Padding (zero/invalid id) → end of frames.
            guard let c = id.unicodeScalars.first,
                  (c.properties.isAlphabetic || ("0"..."9").contains(Character(c))),
                  id.allSatisfy({ $0.isLetter || $0.isNumber }) else { break }
            let size = syncsafeFrames ? syncsafe(data, i + 4) : plainUInt32(data, i + 4)
            guard size > 0, i + 10 + size <= to else { break }
            let content = data.subdata(in: (i + 10) ..< (i + 10 + size))
            frames.append(Frame(id: id, content: content))
            i += 10 + size
        }
    }

    private static func syncsafe(_ data: Data, _ offset: Int) -> Int {
        let s = data.startIndex + offset
        return Int(data[s]) << 21 | Int(data[s + 1]) << 14 | Int(data[s + 2]) << 7 | Int(data[s + 3])
    }
    private static func plainUInt32(_ data: Data, _ offset: Int) -> Int {
        let s = data.startIndex + offset
        return Int(data[s]) << 24 | Int(data[s + 1]) << 16 | Int(data[s + 2]) << 8 | Int(data[s + 3])
    }
    private static func encodeSyncsafe(_ n: Int) -> [UInt8] {
        [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)]
    }
    private static func str(_ data: Data, _ offset: Int, _ len: Int) -> String {
        let s = data.startIndex + offset
        return String(bytes: data[s ..< s + len], encoding: .isoLatin1) ?? ""
    }
}

// MARK: - FLAC (Vorbis comments)

private enum FLAC {
    static let key: [String: String] = [
        "title": "TITLE", "artist": "ARTIST", "album": "ALBUM",
        "albumArtist": "ALBUMARTIST", "composer": "COMPOSER",
    ]

    static func write(_ edits: TagEdits, into file: Data) throws -> Data {
        guard file.count > 4, String(bytes: file[file.startIndex ..< file.startIndex + 4], encoding: .ascii) == "fLaC" else {
            throw TagWriter.TagError.malformed("not a FLAC stream")
        }
        // Walk metadata blocks: [1 byte last+type][3 byte length][data].
        var i = file.startIndex + 4
        var blocks: [(type: Int, last: Bool, data: Data)] = []
        while i + 4 <= file.endIndex {
            let header = file[i]
            let last = (header & 0x80) != 0
            let type = Int(header & 0x7F)
            let len = Int(file[i + 1]) << 16 | Int(file[i + 2]) << 8 | Int(file[i + 3])
            let start = i + 4
            guard start + len <= file.endIndex else { throw TagWriter.TagError.malformed("truncated FLAC block") }
            blocks.append((type, last, file.subdata(in: start ..< start + len)))
            i = start + len
            if last { break }
        }
        let audio = file.subdata(in: i ..< file.endIndex)

        // Comments from the existing VORBIS_COMMENT block (type 4), or fresh.
        var vendor = "MuonPlayer"
        var comments: [String] = []
        if let vc = blocks.first(where: { $0.type == 4 }) {
            (vendor, comments) = VorbisComment.parse(vc.data)
        }
        VorbisComment.apply(edits, to: &comments)

        let newVorbis = VorbisComment.build(vendor: vendor, comments: comments)
        blocks.removeAll { $0.type == 4 }
        blocks.append((4, false, newVorbis))

        // Reassemble, marking the final block as last.
        var out = Data()
        out.append("fLaC".data(using: .ascii)!)
        for (idx, block) in blocks.enumerated() {
            let isLast = idx == blocks.count - 1
            out.append(UInt8((isLast ? 0x80 : 0) | (block.type & 0x7F)))
            out.append(contentsOf: [UInt8((block.data.count >> 16) & 0xFF),
                                    UInt8((block.data.count >> 8) & 0xFF),
                                    UInt8(block.data.count & 0xFF)])
            out.append(block.data)
        }
        out.append(audio)
        return out
    }

}

// MARK: - Vorbis comment payload (shared by FLAC and Ogg)

private enum VorbisComment {
    /// Parse [vendor_len LE][vendor][count LE][ len LE + "KEY=value" ]*.
    static func parse(_ d: Data) -> (vendor: String, comments: [String]) {
        var i = d.startIndex
        func u32le() -> Int {
            let v = Int(d[i]) | Int(d[i + 1]) << 8 | Int(d[i + 2]) << 16 | Int(d[i + 3]) << 24
            i += 4; return v
        }
        guard i + 4 <= d.endIndex else { return ("MuonPlayer", []) }
        let vlen = u32le()
        let vendor = String(bytes: d[i ..< min(i + vlen, d.endIndex)], encoding: .utf8) ?? ""
        i += vlen
        guard i + 4 <= d.endIndex else { return (vendor, []) }
        let count = u32le()
        var comments: [String] = []
        for _ in 0..<count {
            guard i + 4 <= d.endIndex else { break }
            let len = u32le()
            guard i + len <= d.endIndex else { break }
            if let s = String(bytes: d[i ..< i + len], encoding: .utf8) { comments.append(s) }
            i += len
        }
        return (vendor, comments)
    }

    static func build(vendor: String, comments: [String]) -> Data {
        var d = Data()
        func appendLE(_ n: Int) { d.append(contentsOf: [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)]) }
        let v = vendor.data(using: .utf8) ?? Data()
        appendLE(v.count); d.append(v)
        appendLE(comments.count)
        for c in comments {
            let cd = c.data(using: .utf8) ?? Data()
            appendLE(cd.count); d.append(cd)
        }
        return d
    }

    /// Replace the standard fields present in `edits` (case-insensitive keys).
    static func apply(_ edits: TagEdits, to comments: inout [String]) {
        func setC(_ key: String, _ value: String?) {
            guard let value else { return }
            comments.removeAll { $0.uppercased().hasPrefix(key + "=") }
            comments.append("\(key)=\(value)")
        }
        setC("TITLE", edits.title)
        setC("ARTIST", edits.artist)
        setC("ALBUM", edits.album)
        setC("ALBUMARTIST", edits.albumArtist)
        setC("COMPOSER", edits.composer)
        if let trk = edits.trackNo { setC("TRACKNUMBER", String(trk)) }
    }
}

// MARK: - Ogg (Vorbis / Opus comment headers)

private enum Ogg {
    struct Page {
        var raw: Data
        var headerType: UInt8
        var serial: UInt32
        var segTable: [UInt8]
        var data: Data
    }

    static func write(_ edits: TagEdits, into file: Data) throws -> Data {
        guard file.count > 27, str(file, 0, 4) == "OggS" else {
            throw TagWriter.TagError.malformed("not an Ogg stream")
        }
        let pages = try parse(file)
        guard let first = pages.first else { throw TagWriter.TagError.malformed("no Ogg pages") }
        let serial = first.serial

        // Codec + number of setup/header packets before audio.
        let isOpus = first.data.count >= 8 && String(bytes: first.data[first.data.startIndex ..< first.data.startIndex + 8], encoding: .ascii) == "OpusHead"
        let isVorbis = first.data.count >= 7 && first.data[first.data.startIndex] == 0x01
            && String(bytes: first.data[first.data.startIndex + 1 ..< first.data.startIndex + 7], encoding: .ascii) == "vorbis"
        guard isOpus || isVorbis else { throw TagWriter.TagError.unsupportedFormat("ogg (unknown codec)") }
        let headerPacketCount = isOpus ? 2 : 3

        // Reassemble header packets and find where audio pages begin.
        var packets: [Data] = []
        var buf = Data()
        var audioPageStart = pages.count
        outer: for (idx, page) in pages.enumerated() {
            var p = page.data.startIndex
            for seg in page.segTable {
                let len = Int(seg)
                buf.append(page.data[p ..< p + len]); p += len
                if len < 255 {
                    packets.append(buf); buf = Data()
                    if packets.count == headerPacketCount { audioPageStart = idx + 1; break outer }
                }
            }
        }
        guard packets.count >= headerPacketCount else { throw TagWriter.TagError.malformed("missing Ogg header packets") }

        // Edit the comment packet (packet index 1).
        packets[1] = editComment(packets[1], isOpus: isOpus, edits: edits)

        // Repaginate the header packets, then append the (renumbered) audio pages.
        let headerPages = paginate(packets, serial: serial)
        var out = Data()
        for pg in headerPages { out.append(pg) }
        let newHeaderCount = UInt32(headerPages.count)
        for (j, page) in pages[audioPageStart...].enumerated() {
            out.append(renumber(page.raw, seq: newHeaderCount + UInt32(j)))
        }
        return out
    }

    private static func editComment(_ packet: Data, isOpus: Bool, edits: TagEdits) -> Data {
        let prefixLen = isOpus ? 8 : 7          // "OpusTags" or 0x03"vorbis"
        let s = packet.startIndex
        let core = packet.count > prefixLen ? packet.subdata(in: s + prefixLen ..< packet.endIndex) : Data()
        var (vendor, comments) = VorbisComment.parse(core)
        // (For vorbis the trailing framing bit is ignored by parse.)
        VorbisComment.apply(edits, to: &comments)
        var out = Data()
        out.append(packet.subdata(in: s ..< s + prefixLen))    // keep the codec prefix
        out.append(VorbisComment.build(vendor: vendor, comments: comments))
        if !isOpus { out.append(0x01) }                        // vorbis framing bit
        return out
    }

    // MARK: Ogg page parse / build

    private static func parse(_ file: Data) throws -> [Page] {
        var pages: [Page] = []
        var i = file.startIndex
        while i + 27 <= file.endIndex {
            guard String(bytes: file[i ..< i + 4], encoding: .ascii) == "OggS" else { break }
            let headerType = file[i + 5]
            let serial = le32(file, i + 14)
            let nsegs = Int(file[i + 26])
            guard i + 27 + nsegs <= file.endIndex else { throw TagWriter.TagError.malformed("bad Ogg segtable") }
            let segTable = Array(file[i + 27 ..< i + 27 + nsegs])
            let dataLen = segTable.reduce(0) { $0 + Int($1) }
            let dataStart = i + 27 + nsegs
            guard dataStart + dataLen <= file.endIndex else { throw TagWriter.TagError.malformed("truncated Ogg page") }
            let pageLen = 27 + nsegs + dataLen
            pages.append(Page(raw: file.subdata(in: i ..< i + pageLen),
                              headerType: headerType, serial: serial,
                              segTable: segTable,
                              data: file.subdata(in: dataStart ..< dataStart + dataLen)))
            i += pageLen
        }
        return pages
    }

    /// Paginate header packets into pages (granule 0, BOS on the first).
    private static func paginate(_ packets: [Data], serial: UInt32) -> [Data] {
        var lacings: [UInt8] = []
        var payload = Data()
        for pkt in packets {
            var l = pkt.count
            while l >= 255 { lacings.append(255); l -= 255 }
            lacings.append(UInt8(l))
            payload.append(pkt)
        }
        var out: [Data] = []
        var li = 0, payOff = payload.startIndex
        var seq: UInt32 = 0
        var prevLastWas255 = false
        while li < lacings.count {
            let take = min(255, lacings.count - li)
            let chunk = Array(lacings[li ..< li + take])
            let dataLen = chunk.reduce(0) { $0 + Int($1) }
            let pdata = payload.subdata(in: payOff ..< payOff + dataLen)
            var headerType: UInt8 = 0
            if seq == 0 { headerType |= 0x02 }            // BOS
            if seq > 0 && prevLastWas255 { headerType |= 0x01 } // continuation
            out.append(buildPage(headerType: headerType, granule: 0, serial: serial, seq: seq, segTable: chunk, data: pdata))
            prevLastWas255 = (chunk.last == 255)
            li += take; payOff += dataLen; seq += 1
        }
        return out
    }

    private static func buildPage(headerType: UInt8, granule: UInt64, serial: UInt32, seq: UInt32, segTable: [UInt8], data: Data) -> Data {
        var p = Data()
        p.append("OggS".data(using: .ascii)!)
        p.append(0)                        // version
        p.append(headerType)
        p.append(contentsOf: le64Bytes(granule))
        p.append(contentsOf: le32Bytes(serial))
        p.append(contentsOf: le32Bytes(seq))
        p.append(contentsOf: [0, 0, 0, 0]) // CRC placeholder
        p.append(UInt8(segTable.count))
        p.append(contentsOf: segTable)
        p.append(data)
        let crc = crc32(p)
        let b = le32Bytes(crc)
        for k in 0..<4 { p[p.startIndex + 22 + k] = b[k] }
        return p
    }

    /// Rewrite an existing audio page's sequence number and CRC in place.
    private static func renumber(_ raw: Data, seq: UInt32) -> Data {
        var p = raw
        let b = le32Bytes(seq)
        for k in 0..<4 { p[p.startIndex + 18 + k] = b[k] }
        for k in 0..<4 { p[p.startIndex + 22 + k] = 0 }
        let crc = crc32(p)
        let c = le32Bytes(crc)
        for k in 0..<4 { p[p.startIndex + 22 + k] = c[k] }
        return p
    }

    // MARK: Helpers

    private static func str(_ d: Data, _ o: Int, _ n: Int) -> String {
        String(bytes: d[d.startIndex + o ..< d.startIndex + o + n], encoding: .ascii) ?? ""
    }
    private static func le32(_ d: Data, _ o: Int) -> UInt32 {
        let s = d.startIndex + o
        return UInt32(d[s]) | UInt32(d[s + 1]) << 8 | UInt32(d[s + 2]) << 16 | UInt32(d[s + 3]) << 24
    }
    private static func le32Bytes(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
    private static func le64Bytes(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * $0)) & 0xFF) } }

    // Ogg CRC-32 (poly 0x04C11DB7, no reflection, init 0).
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var r = UInt32(i) << 24
            for _ in 0..<8 { r = (r & 0x8000_0000) != 0 ? (r << 1) ^ 0x04C1_1DB7 : (r << 1) }
            return r
        }
    }()
    private static func crc32(_ d: Data) -> UInt32 {
        var crc: UInt32 = 0
        for b in d { crc = (crc << 8) ^ table[Int(((crc >> 24) & 0xFF) ^ UInt32(b))] }
        return crc
    }
}
