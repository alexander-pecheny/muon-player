import SwiftUI

/// The omni-search results — matching artists, albums and songs across the whole
/// library. Shown in place of the current section whenever the toolbar search
/// field holds a query (see `MacRootView`).
struct MacSearchResultsView: View {
    @Environment(MacRouter.self) private var router
    let query: String

    @Environment(LibraryStore.self) private var library
    @State private var results = SearchResults()
    @State private var searched = ""

    var body: some View {
        Group {
            if results.isEmpty {
                ContentUnavailableView.search(text: searched)
            } else {
                resultsList
            }
        }
        .navigationTitle("Search")
        // Typing must not wait on the library. The pause lets a run of keystrokes
        // land before any query is issued — the intermediate prefixes ("l", "lo")
        // are the expensive ones and nobody wants to see them.
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let found = await library.searchAll(query)
            guard !Task.isCancelled else { return }
            results = found
            searched = query
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
                        .commandClickOpens { router.openArtist(artist.name) }
                        .contextMenu {
                            Button("Open in New Tab") { router.openArtist(artist.name, inNewTab: true) }
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
                        .commandClickOpens { router.openAlbum(album) }
                        .contextMenu {
                            Button("Open in New Tab") { router.openAlbum(album, inNewTab: true) }
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
