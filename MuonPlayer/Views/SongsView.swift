import SwiftUI

struct SongsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @State private var tracks: [Track] = []
    @State private var query = ""

    private var filtered: [Track] {
        guard !query.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            ($0.artist?.localizedCaseInsensitiveContains(query) ?? false) ||
            ($0.album?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        List {
            ForEach(filtered) { track in
                TrackRow(track: track, isCurrent: player.currentTrack?.url == track.url)
                    .contentShape(Rectangle())
                    .onTapGesture { player.play(track: track, context: filtered) }
                    .swipeActions(edge: .trailing) {
                        Button {
                            player.enqueue(track, context: filtered)
                        } label: { Label("Enqueue", systemImage: "text.append") }
                        .tint(player.accentColor)
                    }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter songs")
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView("No Songs", systemImage: "music.note")
            }
        }
        .task(id: library.trackCount) { tracks = await library.allTracks() }
    }
}
