import Foundation

enum AudioFormat: String, Sendable {
    case mp3
    case m4a
    case aac
    case aif
    case aiff
    case wav
    case caf
    case flac
    case ogg
    case oga
    case opus
    case wma
    case alac
    case ape
    case wv
    case mka
    case unknown

    /// Everything the scanner picks up. Decoding is handled by FFmpeg, so this
    /// is a superset of what AVFoundation supports natively.
    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "aif", "aiff", "wav", "caf",
        "flac", "ogg", "oga", "opus", "wma", "alac", "ape", "wv", "mka",
    ]

    init(fileExtension: String) {
        self = AudioFormat(rawValue: fileExtension.lowercased()) ?? .unknown
    }
}

/// A playable/displayable track. `id` is a stable per-session identity used by
/// SwiftUI and the play queue. `libraryID` is the SQLite row id when the track
/// came from the library.
struct Track: Identifiable, Sendable, Hashable {
    let id: UUID
    let libraryID: Int64?
    let url: URL
    let title: String
    let artist: String?
    let album: String?
    let albumArtist: String?
    let composer: String?
    let trackNo: Int?
    let discNo: Int?
    let duration: TimeInterval?
    let bitrate: Int?      // bits per second
    let codec: String?     // decoder codec name, e.g. "aac", "flac", "alac"
    let hasArtwork: Bool
    let format: AudioFormat

    init(
        id: UUID = UUID(),
        libraryID: Int64? = nil,
        url: URL,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        composer: String? = nil,
        trackNo: Int? = nil,
        discNo: Int? = nil,
        duration: TimeInterval? = nil,
        bitrate: Int? = nil,
        codec: String? = nil,
        hasArtwork: Bool = false
    ) {
        self.id = id
        self.libraryID = libraryID
        self.url = url
        self.title = title ?? Track.displayName(from: url)
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.composer = composer
        self.trackNo = trackNo
        self.discNo = discNo
        self.duration = duration
        self.bitrate = bitrate
        self.codec = codec
        self.hasArtwork = hasArtwork
        self.format = AudioFormat(fileExtension: url.pathExtension)
    }

    /// The artist used for grouping albums (album artist, falling back to artist).
    var effectiveAlbumArtist: String {
        albumArtist ?? artist ?? "Unknown Artist"
    }

    var displayArtist: String {
        artist ?? albumArtist ?? "Unknown Artist"
    }

    var displayAlbum: String {
        album ?? "Unknown Album"
    }

    static func displayName(from url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Human-readable codec/format label, e.g. "FLAC", "AAC", "ALAC", "MP3".
    var formatLabel: String {
        if let codec { return Track.codecLabel(codec) }
        return url.pathExtension.uppercased()
    }

    /// Bitrate in kbps for display, if known.
    var bitrateKbps: Int? {
        guard let bitrate, bitrate > 0 else { return nil }
        return Int((Double(bitrate) / 1000.0).rounded())
    }

    /// Combined "AAC · 256 kbps" style label.
    var formatDescription: String {
        if let kbps = bitrateKbps { return "\(formatLabel) · \(kbps) kbps" }
        return formatLabel
    }

    private static func codecLabel(_ codec: String) -> String {
        switch codec.lowercased() {
        case "aac": return "AAC"
        case "alac": return "ALAC"
        case "flac": return "FLAC"
        case "mp3", "mp3float": return "MP3"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "wmav1", "wmav2": return "WMA"
        case "ac3": return "AC-3"
        case "eac3": return "E-AC-3"
        case "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_s16be", "pcm_f32be": return "PCM"
        default: return codec.uppercased()
        }
    }
}
