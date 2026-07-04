import SwiftUI

/// Navigation value for pushing an artist's album list.
struct ArtistRef: Hashable, Identifiable {
    let name: String
    var id: String { name }
}

/// All albums grouped under one artist (album-artist), shown as a chronological
/// grid (like the Albums tab), oldest first.
struct ArtistView: View {
    let artist: String
    @Environment(LibraryStore.self) private var library

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    // Chronological discography: by year (undated last), then title.
    private var albums: [Album] {
        library.albums
            .filter { $0.artist == artist }
            .sorted {
                let ya = $0.year ?? Int.max, yb = $1.year ?? Int.max
                if ya != yb { return ya < yb }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkView(path: album.artworkPath)
                                .aspectRatio(1, contentMode: .fit)
                                .shadow(radius: 2, y: 1)
                            Text(album.title)
                                .font(.subheadline.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                            if let y = album.year {
                                Text(String(y))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(artist)
        .navigationBarTitleDisplayMode(.inline)
    }
}
