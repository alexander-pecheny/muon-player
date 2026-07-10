import SwiftUI

/// The omni-search results — matching artists, albums and songs across the whole
/// library. Shown in place of the current section whenever the toolbar search
/// field holds a query (see `MacRootView`).
struct MacSearchResultsView: View {
    let query: String

    @Environment(LibraryStore.self) private var library
    @State private var results = SearchResults()

    var body: some View {
        Group {
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                resultsList
            }
        }
        .navigationTitle("Search")
        .task(id: query) { results = await library.searchAll(query) }
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
