import SwiftUI

struct MacSongsView: View {
    @Environment(LibraryStore.self) private var library
    @State private var tracks: [Track] = []
    @State private var query = ""

    private var shown: [Track] {
        guard !query.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.displayArtist.localizedCaseInsensitiveContains(query)
                || $0.displayAlbum.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List(shown) { track in
            MacTrackRow(track: track, context: shown, showArtwork: true)
        }
        .listStyle(.inset)
        .overlay {
            if shown.isEmpty {
                ContentUnavailableView(tracks.isEmpty ? "No Songs" : "No Results",
                                       systemImage: "music.note.list")
            }
        }
        .searchable(text: $query, prompt: "Filter songs")
        .navigationTitle("Songs")
        .task(id: library.trackCount) { tracks = await library.allTracks() }
    }
}
