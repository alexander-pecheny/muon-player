import SwiftUI

/// Search across the whole library; with an empty query, the newest additions.
struct MacHomeView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(MacRouter.self) private var router
    @State private var query = ""
    @State private var results = SearchResults()
    @State private var recent: [Album] = []

    var body: some View {
        Group {
            if query.isEmpty {
                recentlyAdded
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                resultsList
            }
        }
        .searchable(text: $query, prompt: "Search artists, albums and songs")
        .navigationTitle("Home")
        .task(id: library.version) { recent = await library.recentAlbums() }
        .task(id: query) {
            results = await library.searchAll(query)
        }
    }

    private var recentlyAdded: some View {
        VStack(alignment: .leading, spacing: 0) {
            if recent.isEmpty {
                ContentUnavailableView("Library Is Empty", systemImage: "music.note.house",
                                       description: Text("Add a folder from the Library menu."))
            } else {
                AlbumGrid(albums: recent)
            }
        }
    }

    private var resultsList: some View {
        List {
            if !results.artists.isEmpty {
                Section("Artists") {
                    ForEach(results.artists) { artist in
                        NavigationLink(value: ArtistRef(name: artist.name)) {
                            HStack(spacing: 10) {
                                ArtworkView(path: artist.artworkPath, cornerRadius: 16)
                                    .frame(width: 32, height: 32)
                                    .clipShape(Circle())
                                Text(artist.name)
                            }
                        }
                    }
                }
            }
            if !results.albums.isEmpty {
                Section("Albums") {
                    ForEach(results.albums) { album in
                        NavigationLink(value: album) {
                            HStack(spacing: 10) {
                                ArtworkView(path: album.artworkPath, cornerRadius: 3)
                                    .frame(width: 32, height: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(album.title).lineLimit(1)
                                    Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            if !results.songs.isEmpty {
                Section("Songs") {
                    ForEach(results.songs) { track in
                        MacTrackRow(track: track, context: results.songs, showArtwork: true, showFolder: false)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}
