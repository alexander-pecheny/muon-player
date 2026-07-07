import SwiftUI

struct AlbumsView: View {
    @Environment(LibraryStore.self) private var library
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    private var filtered: [Album] {
        guard !query.isEmpty else { return library.albums }
        return library.albums.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.artist.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            if library.albums.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(filtered) { album in
                        NavigationLink(value: album) {
                            AlbumCell(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter albums")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if library.isScanning {
                    ProgressView()
                } else {
                    Button {
                        Task { await library.rescan() }
                    } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Music", systemImage: "music.note")
        } description: {
            Text("Add audio files to **On My iPhone → MuonPlayer** in the Files app, then pull to refresh.")
        } actions: {
            Button("Rescan") { Task { await library.rescan() } }
        }
        .padding(.top, 80)
    }
}

private struct AlbumCell: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(path: album.artworkPath)
                .aspectRatio(1, contentMode: .fit)
                .shadow(radius: 2, y: 1)
            Text(album.title)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(album.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
