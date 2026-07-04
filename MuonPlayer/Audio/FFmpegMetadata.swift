import Foundation
import CFFmpeg

/// Tags + artwork read straight from the container via libavformat, so it works
/// for every format FFmpeg can demux (including ogg/opus/flac that AVFoundation
/// can't parse).
struct TrackMetadata {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNo: Int?
    var discNo: Int?
    var duration: TimeInterval?
    var hasArtwork: Bool = false
    var artwork: Data?
}

enum FFmpegMetadata {
    private static let attachedPicDisposition: Int32 = 0x0400 // AV_DISPOSITION_ATTACHED_PIC

    static func read(url: URL, includeArtwork: Bool = true) -> TrackMetadata {
        var meta = TrackMetadata()
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        let rc = url.path.withCString { avformat_open_input(&ctx, $0, nil, nil) }
        guard rc == 0, let ctx else { return meta }
        defer { var c: UnsafeMutablePointer<AVFormatContext>? = ctx; avformat_close_input(&c) }
        avformat_find_stream_info(ctx, nil)

        if ctx.pointee.duration > 0 {
            meta.duration = Double(ctx.pointee.duration) / Double(AV_TIME_BASE)
        }

        // Container-level tags, then merge any stream-level tags (some formats
        // put them on the audio stream).
        readTags(into: &meta, from: ctx.pointee.metadata)
        let nb = Int(ctx.pointee.nb_streams)
        for i in 0..<nb {
            guard let stream = ctx.pointee.streams[i] else { continue }
            readTags(into: &meta, from: stream.pointee.metadata, overwrite: false)

            if (stream.pointee.disposition & attachedPicDisposition) != 0 {
                meta.hasArtwork = true
                if includeArtwork, meta.artwork == nil {
                    let pic = stream.pointee.attached_pic
                    if pic.size > 0, let data = pic.data {
                        meta.artwork = Data(bytes: data, count: Int(pic.size))
                    }
                }
            }
        }

        // Ogg/Opus/Vorbis store covers as a base64 FLAC picture block in a tag.
        if !meta.hasArtwork || (includeArtwork && meta.artwork == nil) {
            if let art = extractBase64Picture(from: ctx.pointee.metadata) {
                meta.hasArtwork = true
                if includeArtwork { meta.artwork = art }
            }
        }
        return meta
    }

    private static func readTags(into meta: inout TrackMetadata,
                                 from dict: OpaquePointer?,
                                 overwrite: Bool = true) {
        func value(_ key: String) -> String? {
            guard let entry = av_dict_get(dict, key, nil, AV_DICT_IGNORE_SUFFIX),
                  let v = entry.pointee.value else { return nil }
            let s = String(cString: v).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        func set(_ current: inout String?, _ key: String) {
            if let v = value(key), overwrite || current == nil { current = v }
        }
        set(&meta.title, "title")
        set(&meta.artist, "artist")
        set(&meta.album, "album")
        if let v = value("album_artist"), overwrite || meta.albumArtist == nil { meta.albumArtist = v }
        else if let v = value("albumartist"), overwrite || meta.albumArtist == nil { meta.albumArtist = v }
        if let t = value("track"), let n = leadingInt(t), overwrite || meta.trackNo == nil { meta.trackNo = n }
        if let d = value("disc"), let n = leadingInt(d), overwrite || meta.discNo == nil { meta.discNo = n }
        else if let d = value("discnumber"), let n = leadingInt(d), overwrite || meta.discNo == nil { meta.discNo = n }
    }

    private static func leadingInt(_ s: String) -> Int? {
        let head = s.prefix { $0.isNumber }
        return Int(head)
    }

    /// Vorbis comment cover art: METADATA_BLOCK_PICTURE is a base64-encoded FLAC
    /// picture block; the image bytes live after a fixed header we skip past.
    private static func extractBase64Picture(from dict: OpaquePointer?) -> Data? {
        guard let entry = av_dict_get(dict, "METADATA_BLOCK_PICTURE", nil, AV_DICT_IGNORE_SUFFIX)
                ?? av_dict_get(dict, "metadata_block_picture", nil, AV_DICT_IGNORE_SUFFIX),
              let v = entry.pointee.value,
              let blob = Data(base64Encoded: String(cString: v)) else { return nil }
        return parseFLACPictureBlock(blob)
    }

    /// FLAC picture block layout: type(4) + mimeLen(4) + mime + descLen(4) + desc
    /// + width(4)+height(4)+depth(4)+colors(4) + dataLen(4) + data.
    private static func parseFLACPictureBlock(_ d: Data) -> Data? {
        var i = 0
        func u32() -> Int? {
            guard i + 4 <= d.count else { return nil }
            let b = d[d.startIndex + i ..< d.startIndex + i + 4]
            i += 4
            return b.reduce(0) { ($0 << 8) | Int($1) }
        }
        guard u32() != nil else { return nil }             // picture type
        guard let mimeLen = u32() else { return nil }; i += mimeLen
        guard let descLen = u32() else { return nil }; i += descLen
        guard u32() != nil, u32() != nil, u32() != nil, u32() != nil else { return nil } // w,h,depth,colors
        guard let dataLen = u32(), i + dataLen <= d.count else { return nil }
        return d.subdata(in: (d.startIndex + i) ..< (d.startIndex + i + dataLen))
    }
}
