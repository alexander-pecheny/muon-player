import SwiftUI

struct MacArtistsView: View {
    @Environment(LibraryStore.self) private var library
    @State private var query = ""

    private var artists: [ArtistResult] {
        let names = Set(library.albums.map(\.artist))
        return names
            .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name in
                ArtistResult(name: name,
                             artworkPath: library.albums.first { $0.artist == name && $0.artworkPath != nil }?.artworkPath)
            }
    }

    var body: some View {
        List(artists) { artist in
            NavigationLink(value: ArtistRef(name: artist.name)) {
                HStack(spacing: 10) {
                    ArtworkView(path: artist.artworkPath, cornerRadius: 18)
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                    Text(artist.name)
                }
                .padding(.vertical, 2)
            }
        }
        .overlay {
            if artists.isEmpty {
                ContentUnavailableView(library.albums.isEmpty ? "No Artists" : "No Results",
                                       systemImage: "music.mic")
            }
        }
        .searchable(text: $query, prompt: "Filter artists")
        .navigationTitle("Artists")
    }
}

/// An artist's discography, oldest release first.
struct MacArtistView: View {
    let artist: String
    @Environment(LibraryStore.self) private var library

    private var albums: [Album] {
        library.albums
            .filter { $0.artist == artist }
            .sorted { ($0.year ?? .max, $0.title) < ($1.year ?? .max, $1.title) }
    }

    var body: some View {
        AlbumGrid(albums: albums)
            .navigationTitle(artist)
    }
}
