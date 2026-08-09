import SwiftUI

/// All artists (album-artists) in the library. Tapping one opens its albums.
struct ArtistsView: View {
    @Environment(LibraryStore.self) private var library
    @State private var query = ""

    private struct ArtistSummary: Identifiable {
        let name: String
        let albumCount: Int
        let artworkPath: String?
        var id: String { name }
    }

    private var artists: [ArtistSummary] {
        var byArtist: [String: [Album]] = [:]
        for album in library.albums { byArtist[album.artist, default: []].append(album) }
        return byArtist
            .map { name, albums in
                // Represent the artist with their earliest album that has artwork.
                let sorted = albums.sorted { ($0.year ?? Int.max) < ($1.year ?? Int.max) }
                let art = sorted.first(where: { $0.artworkPath != nil })?.artworkPath
                return ArtistSummary(name: name, albumCount: albums.count, artworkPath: art)
            }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            ForEach(artists) { artist in
                NavigationLink(value: ArtistRef(name: artist.name)) {
                    HStack(spacing: 12) {
                        ArtworkView(path: artist.artworkPath, cornerRadius: 6)
                            .frame(width: 48, height: 48)
                        Text(artist.name)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text("\(artist.albumCount)")
                            .font(.caption.tabularDigits).tertiaryForeground()
                    }
                }
            }
        }
        .listStyle(.plain)
        .filterSearchable(text: $query, prompt: "Filter artists")
        .overlay {
            if artists.isEmpty {
                ContentUnavailableView("No Artists", systemImage: "music.mic")
            }
        }
    }
}
