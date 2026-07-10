import SwiftUI

/// A resizable grid of album covers. Clicking a cover drills into the album.
struct MacAlbumsView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        AlbumGrid(albums: library.albums)
            .overlay {
                if library.albums.isEmpty {
                    ContentUnavailableView("No Albums", systemImage: "square.stack")
                }
            }
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
                    AlbumCell(album: album)
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
    @Environment(MacRouter.self) private var router
    @State private var editing = false

    /// The cover and title link to the album, the caption to the artist. The
    /// artist button is a sibling of the NavigationLink, not nested inside its
    /// label — a button in there never sees the click, and swallows it besides.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink(value: album) {
                VStack(alignment: .leading, spacing: 6) {
                    ArtworkView(path: album.artworkPath, cornerRadius: 6)
                        .aspectRatio(1, contentMode: .fit)
                        .shadow(radius: 2, y: 1)
                    Text(album.title).font(.callout).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                Button { router.openArtist(album.artist) } label: {
                    Text(album.artist).lineLimit(1)
                }
                .buttonStyle(.plain)
                if let year = album.year {
                    Text("· \(String(year))")
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Play") { Task { await play() } }
            Button("Add to Queue") { Task { await enqueue() } }
            Divider()
            Button("Go to Artist") { router.openArtist(album.artist) }
            Button("Edit Tags…") { editing = true }
            Button("Reveal in Finder") { Task { await reveal() } }
        }
        .sheet(isPresented: $editing) { MacTagEditView(scope: .album(album)) }
    }

    private func reveal() async {
        guard let first = await library.tracks(in: album).first else { return }
        revealInFinder(first.url)
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
