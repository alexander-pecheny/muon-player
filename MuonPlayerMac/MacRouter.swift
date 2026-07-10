import Observation
import SwiftUI

/// Sidebar selection plus a navigation path per section, so switching sections
/// and coming back restores where you were. Deep links from the Now Playing
/// inspector (artist / album) push onto whichever section is showing.
@MainActor
@Observable
final class MacRouter {
    enum Section: String, CaseIterable, Identifiable {
        case home, albums, artists, songs, folders, history
        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: return "Home"
            case .albums: return "Albums"
            case .artists: return "Artists"
            case .songs: return "Songs"
            case .folders: return "Folders"
            case .history: return "History"
            }
        }

        var systemImage: String {
            switch self {
            case .home: return "house"
            case .albums: return "square.stack"
            case .artists: return "music.mic"
            case .songs: return "music.note.list"
            case .folders: return "folder"
            case .history: return "clock"
            }
        }
    }

    var section: Section = .albums
    var showNowPlaying = false
    var showQueue = false

    private var paths: [Section: NavigationPath] = [:]

    var path: Binding<NavigationPath> {
        Binding(get: { self.paths[self.section] ?? NavigationPath() },
                set: { self.paths[self.section] = $0 })
    }

    private func push<V: Hashable>(_ value: V) {
        var p = paths[section] ?? NavigationPath()
        p.append(value)
        paths[section] = p
    }

    func openArtist(_ name: String) {
        showQueue = false
        push(ArtistRef(name: name))
    }

    /// `focus` is the path of a track to scroll to — set when the user clicked a
    /// song name rather than an album name.
    func openAlbum(_ album: Album, focus: String? = nil) {
        showQueue = false
        if let focus { push(AlbumRef(album: album, focusPath: focus)) } else { push(album) }
    }
}
