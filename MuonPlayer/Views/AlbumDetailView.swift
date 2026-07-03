import SwiftUI

struct AlbumDetailView: View {
    let album: Album
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @State private var tracks: [Track] = []

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ArtworkView(path: album.artworkPath, cornerRadius: 12)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 320)
                        .shadow(radius: 8, y: 4)
                        .padding(.top, 8)

                    VStack(spacing: 2) {
                        Text(album.title).font(.title3.bold()).multilineTextAlignment(.center)
                        Text(album.artist).foregroundStyle(.secondary)
                        Text("\(album.trackCount) track\(album.trackCount == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.tertiary)
                    }

                    HStack(spacing: 12) {
                        Button {
                            if let first = tracks.first { player.play(track: first, context: tracks) }
                        } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            for t in tracks { player.enqueue(t, context: tracks) }
                        } label: {
                            Label("Queue", systemImage: "text.append").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal)
                }
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
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
        }
        .listStyle(.plain)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { tracks = await library.tracks(in: album) }
    }
}

struct TrackRow: View {
    let track: Track
    var isCurrent: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            if let n = track.trackNo {
                Text("\(n)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)
                if let artist = track.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(Color.accentColor)
            }
            if let d = track.duration {
                Text(formatDuration(d)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return String(format: "%d:%02d", mins, secs)
}
