import SwiftUI

/// A resizable grid of album covers. Clicking a cover drills into the album.
struct MacAlbumsView: View {
    @Environment(LibraryStore.self) private var library
    @State private var query = ""

    private var shown: [Album] {
        guard !query.isEmpty else { return library.albums }
        return library.albums.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        AlbumGrid(albums: shown)
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView(library.albums.isEmpty ? "No Albums" : "No Results",
                                           systemImage: "square.stack")
                }
            }
            .searchable(text: $query, prompt: "Filter albums")
            .navigationTitle("Albums")
    }
}

/// Shared grid used by the Albums section, artist pages and search results.
struct AlbumGrid: View {
    let albums: [Album]
    var columnWidth: CGFloat = 160

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: columnWidth), spacing: 16)], spacing: 18) {
                ForEach(albums) { album in
                    NavigationLink(value: album) { AlbumCell(album: album) }
                        .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }
}

struct AlbumCell: View {
    let album: Album
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(path: album.artworkPath, cornerRadius: 6)
                .aspectRatio(1, contentMode: .fit)
                .shadow(radius: 2, y: 1)
            Text(album.title).font(.callout).lineLimit(1)
            HStack(spacing: 4) {
                Text(album.artist).lineLimit(1)
                if let year = album.year {
                    Text("· \(String(year))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Play") { Task { await play() } }
            Button("Add to Queue") { Task { await enqueue() } }
            Divider()
            Button("Edit Tags…") { editing = true }
        }
        .sheet(isPresented: $editing) { MacTagEditView(scope: .album(album)) }
    }

    private func play() async {
        let tracks = await library.tracks(in: album)
        guard let first = tracks.first else { return }
        player.play(track: first, context: tracks)
    }

    private func enqueue() async {
        let tracks = await library.tracks(in: album)
        for track in tracks { player.enqueue(track, context: tracks) }
    }
}
