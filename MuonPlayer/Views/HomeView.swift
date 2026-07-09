import SwiftUI

/// A grouped search result set: matching artists (top), albums, then songs.
/// The Home tab: a search bar over the whole library that returns artists,
/// albums, and songs; when the query is empty it shows the latest additions to
/// the library instead.
struct HomeView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @State private var query = ""
    @State private var results = SearchResults()
    @State private var recent: [Album] = []
    @State private var searchTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if trimmedQuery.isEmpty {
                latestAdditions
            } else {
                resultsList
            }
        }
        .searchable(text: $query, prompt: "Artists, albums, or songs")
        .task(id: library.trackCount) { recent = await library.recentAlbums() }
        .onChange(of: query) { _, _ in scheduleSearch() }
    }

    // MARK: Latest additions (empty query)

    private var latestAdditions: some View {
        ScrollView {
            if recent.isEmpty {
                ContentUnavailableView("Your Library", systemImage: "house",
                    description: Text("Recently added music appears here. Search above for artists, albums, and songs — in any language."))
                    .padding(.top, 80)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recently Added")
                        .font(.title3.bold())
                        .padding(.horizontal)
                        .padding(.top, 4)
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(recent) { album in
                            NavigationLink(value: album) { albumCell(album) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func albumCell(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(path: album.artworkPath)
                .aspectRatio(1, contentMode: .fit)
                .shadow(radius: 2, y: 1)
            Text(album.title)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(album.artist)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: Search results

    private var resultsList: some View {
        List {
            if !results.artists.isEmpty {
                Section("Artists") {
                    ForEach(results.artists) { artist in
                        NavigationLink(value: ArtistRef(name: artist.name)) {
                            HStack(spacing: 12) {
                                ArtworkView(path: artist.artworkPath, cornerRadius: 6)
                                    .frame(width: 44, height: 44)
                                Text(artist.name)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            if !results.albums.isEmpty {
                Section("Albums") {
                    ForEach(results.albums) { album in
                        NavigationLink(value: album) {
                            HStack(spacing: 12) {
                                ArtworkView(path: album.artworkPath, cornerRadius: 6)
                                    .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.title)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(album.artist)
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
            if !results.songs.isEmpty {
                Section("Songs") {
                    ForEach(results.songs) { track in
                        TrackRow(track: track, isCurrent: player.currentTrack?.url == track.url)
                            .contentShape(Rectangle())
                            .onTapGesture { player.play(track: track, context: results.songs) }
                            .swipeActions(edge: .trailing) {
                                Button {
                                    player.enqueue(track, context: results.songs)
                                } label: { Label("Enqueue", systemImage: "text.append") }
                                .tint(player.accentColor)
                            }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if results.isEmpty {
                ContentUnavailableView("No Results", systemImage: "magnifyingglass",
                    description: Text("Nothing matched “\(trimmedQuery)”."))
            }
        }
    }

    // MARK: Search driver

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = trimmedQuery
        guard !q.isEmpty else { results = SearchResults(); return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let found = await library.searchAll(q)
            guard !Task.isCancelled else { return }
            results = found
        }
    }
}
