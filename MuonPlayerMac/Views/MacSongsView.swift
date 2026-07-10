import SwiftUI

struct MacSongsView: View {
    @Environment(LibraryStore.self) private var library
    @State private var tracks: [Track] = []

    var body: some View {
        List(tracks) { track in
            MacTrackRow(track: track, context: tracks, showArtwork: true)
        }
        .listStyle(.inset)
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView("No Songs", systemImage: "music.note.list")
            }
        }
        .navigationTitle("Songs")
        .task(id: library.version) { tracks = await library.allTracks() }
    }
}
