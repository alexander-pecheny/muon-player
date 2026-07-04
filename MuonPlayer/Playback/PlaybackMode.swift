import Foundation

/// User-facing playback order controls.
///
/// - normal: the "playhead algorithm" — play through the current artist's albums
///   in folder order, looping back to the first album (i.e. repeat-artist).
/// - shuffle: random order within the same artist partition, looping.
/// - repeatTrack: replay the current track forever.
/// - repeatAlbum: loop the current album.
enum PlaybackMode: String, CaseIterable, Sendable {
    case normal
    case shuffle
    case repeatTrack
    case repeatAlbum

    var systemImage: String {
        switch self {
        case .normal: return "arrow.right"
        case .shuffle: return "shuffle"
        case .repeatTrack: return "repeat.1"
        case .repeatAlbum: return "repeat"
        }
    }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .shuffle: return "Shuffle"
        case .repeatTrack: return "Repeat Track"
        case .repeatAlbum: return "Repeat Album"
        }
    }

    /// Cycle order for the toolbar button.
    var next: PlaybackMode {
        switch self {
        case .normal: return .shuffle
        case .shuffle: return .repeatAlbum
        case .repeatAlbum: return .repeatTrack
        case .repeatTrack: return .normal
        }
    }
}
