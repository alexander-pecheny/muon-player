import SwiftUI

struct SearchView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List {
            ForEach(results) { track in
                TrackRow(track: track, isCurrent: player.currentTrack?.url == track.url)
                    .contentShape(Rectangle())
                    .onTapGesture { player.play(track: track, context: results) }
                    .swipeActions(edge: .trailing) {
                        Button {
                            player.enqueue(track, context: results)
                        } label: { Label("Queue", systemImage: "text.append") }
                        .tint(.accentColor)
                    }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Artist, album, or song")
        .overlay {
            if results.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "Search Your Library" : "No Results",
                    systemImage: "magnifyingglass",
                    description: Text(query.isEmpty ? "Search by artist, album, or track — any language." : "Nothing matched “\(query)”.")
                )
            }
        }
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            let q = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { results = []; return }
            // Debounce so search stays instant while typing.
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                let found = await library.search(q)
                guard !Task.isCancelled else { return }
                results = found
            }
        }
    }
}
