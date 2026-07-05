import Foundation

/// User-facing playback order / repeat scope.
///
/// - normal: play through the current album (or queue) once, then stop.
/// - shuffle: play the artist's music in a random order, looping.
/// - repeatTopFolder: repeat every track under the artist's top-level folder
///   (the on-disk "artist folder" — the old "Normal" behaviour).
/// - repeatArtist: repeat every track by the current album-artist (tag-based,
///   across folders), looping.
/// - repeatAlbum: loop the current album.
/// - repeatTrack: replay the current track forever.
enum PlaybackMode: String, CaseIterable, Sendable, Identifiable {
    case normal
    case shuffle
    case repeatTopFolder
    case repeatArtist
    case repeatAlbum
    case repeatTrack

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .normal: return "arrow.forward.to.line"
        case .shuffle: return "shuffle"
        case .repeatTopFolder: return "repeat"
        case .repeatArtist: return "repeat"
        case .repeatAlbum: return "repeat"
        case .repeatTrack: return "repeat.1"
        }
    }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .shuffle: return "Shuffle"
        case .repeatTopFolder: return "Repeat Top Folder"
        case .repeatArtist: return "Repeat Artist"
        case .repeatAlbum: return "Repeat Album"
        case .repeatTrack: return "Repeat Track"
        }
    }

    /// One-line explanation shown under each option in the picker menu.
    var caption: String {
        switch self {
        case .normal: return "Play the album, then stop"
        case .shuffle: return "Shuffle the artist's music"
        case .repeatTopFolder: return "Loop the artist's folder"
        case .repeatArtist: return "Loop everything by this artist"
        case .repeatAlbum: return "Loop this album"
        case .repeatTrack: return "Loop this track"
        }
    }

    /// Whether the context should wrap past its ends (loop).
    var loops: Bool {
        switch self {
        case .normal, .repeatTrack: return false
        case .shuffle, .repeatTopFolder, .repeatArtist, .repeatAlbum: return true
        }
    }

    /// Whether playback should stay on the current track.
    var repeatsOne: Bool { self == .repeatTrack }
}
