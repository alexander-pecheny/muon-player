import SwiftUI

struct SongsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @State private var tracks: [Track] = []

    var body: some View {
        List {
            ForEach(tracks) { track in
                TrackRow(track: track, isCurrent: player.currentTrack?.url == track.url)
                    .contentShape(Rectangle())
                    .onTapGesture { player.play(track: track, context: tracks) }
                    .swipeActions(edge: .trailing) {
                        Button {
                            player.enqueue(track, context: tracks)
                        } label: { Label("Queue", systemImage: "text.append") }
                        .tint(.accentColor)
                    }
            }
        }
        .listStyle(.plain)
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView("No Songs", systemImage: "music.note")
            }
        }
        .task(id: library.trackCount) { tracks = await library.allTracks() }
    }
}
