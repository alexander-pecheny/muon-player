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
    let trackNo: Int?
    let discNo: Int?
    let duration: TimeInterval?
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
        trackNo: Int? = nil,
        discNo: Int? = nil,
        duration: TimeInterval? = nil,
        hasArtwork: Bool = false
    ) {
        self.id = id
        self.libraryID = libraryID
        self.url = url
        self.title = title ?? Track.displayName(from: url)
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.trackNo = trackNo
        self.discNo = discNo
        self.duration = duration
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
}
