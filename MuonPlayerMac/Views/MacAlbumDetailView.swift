import SwiftUI

struct MacAlbumDetailView: View {
    let album: Album

    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @Environment(MacRouter.self) private var router
    @State private var tracks: [Track] = []
    @State private var editing = false

    private var totalDuration: TimeInterval {
        tracks.compactMap(\.duration).reduce(0, +)
    }

    var body: some View {
        List {
            Section { header.listRowSeparator(.hidden) }
            Section {
                ForEach(tracks) { track in
                    MacTrackRow(track: track, context: tracks, showNumber: true)
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle(album.title)
        .toolbar {
            ToolbarItem {
                Button { editing = true } label: { Label("Edit Tags", systemImage: "tag") }
            }
        }
        .sheet(isPresented: $editing) { MacTagEditView(scope: .album(album)) }
        .task(id: album.id) { tracks = await library.tracks(in: album) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            ArtworkView(path: album.artworkPath, cornerRadius: 8)
                .frame(width: 168, height: 168)
                .shadow(radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 6) {
                Text(album.title).font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)

                Button { router.openArtist(album.artist) } label: {
                    Text(album.artist).font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Text(subtitle).font(.caption).foregroundStyle(.tertiary)

                HStack(spacing: 8) {
                    Button {
                        guard let first = tracks.first else { return }
                        player.play(track: first, context: tracks)
                    } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)

                    Button {
                        for track in tracks { player.enqueue(track, context: tracks) }
                    } label: { Label("Add to Queue", systemImage: "text.append") }
                }
                .disabled(tracks.isEmpty)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append("\(tracks.count) track\(tracks.count == 1 ? "" : "s")")
        if totalDuration > 0 { parts.append(formatDuration(totalDuration)) }
        return parts.joined(separator: " · ")
    }
}
