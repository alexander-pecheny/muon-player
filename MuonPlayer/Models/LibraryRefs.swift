import Foundation

/// A navigable reference to an artist (album-artist), used as a navigation value.
struct ArtistRef: Hashable, Identifiable {
    let name: String
    var id: String { name }
}

struct ArtistResult: Identifiable, Hashable {
    let name: String
    let artworkPath: String?
    var id: String { name }
}

struct SearchResults {
    var artists: [ArtistResult] = []
    var albums: [Album] = []
    var songs: [Track] = []
    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
}

/// Navigation value for drilling into a subfolder of the library.
struct FolderRef: Hashable, Identifiable {
    let url: URL
    var id: String { url.path }
}
