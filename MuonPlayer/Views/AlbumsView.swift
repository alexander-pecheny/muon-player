import SwiftUI

struct AlbumsView: View {
    @Environment(LibraryStore.self) private var library

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    var body: some View {
        ScrollView {
            if library.albums.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(library.albums) { album in
                        NavigationLink(value: album) {
                            AlbumCell(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(album: album)
        }
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
        .overlay(alignment: .bottom) {
            if library.isScanning, let p = library.scanProgress {
                Text("Scanning \(p.done)/\(p.total)…")
                    .font(.caption)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 4)
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
                .lineLimit(1)
            Text(album.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
