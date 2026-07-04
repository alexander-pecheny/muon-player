import SwiftUI

struct AlbumDetailView: View {
    let album: Album
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @State private var tracks: [Track] = []
    @State private var editingAlbum = false
    @State private var editingTrack: Track?
    @Environment(\.navPath) private var navPath

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
                        Text(album.artist).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Text("\(album.trackCount) track\(album.trackCount == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.tertiary)
                        if let fmt = formatSummary {
                            Text(fmt).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            if let first = tracks.first { player.play(track: first, context: tracks) }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .labelStyle(.titleAndIcon)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            for t in tracks { player.enqueue(t, context: tracks) }
                        } label: {
                            Label("Queue", systemImage: "text.append")
                                .labelStyle(.titleAndIcon)
                                .frame(maxWidth: .infinity)
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
                    TrackRow(track: track, isCurrent: player.currentTrack?.url == track.url,
                             hideArtist: artistMatchesAlbum(track))
                        .contentShape(Rectangle())
                        .onTapGesture { player.play(track: track, context: tracks) }
                        .swipeActions(edge: .trailing) {
                            Button {
                                player.enqueue(track, context: tracks)
                            } label: { Label("Queue", systemImage: "text.append") }
                            .tint(.accentColor)
                        }
                        .contextMenu { trackMenu(track) }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    albumMenu
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $editingAlbum) { TagEditView(scope: .album(album)) }
        .sheet(item: $editingTrack) { t in TagEditView(scope: .track(t)) }
        .task(id: library.trackCount) { tracks = await library.tracks(in: album) }
    }

    // MARK: Menus

    @ViewBuilder private var albumMenu: some View {
        Button { navPath?.wrappedValue.append(ArtistRef(name: album.artist)) } label: {
            Label("Go to Artist", systemImage: "music.mic")
        }
        Button { for t in tracks { player.enqueue(t, context: tracks) } } label: {
            Label("Add Album to Queue", systemImage: "text.append")
        }
        Button { editingAlbum = true } label: {
            Label("Edit Tags", systemImage: "tag")
        }
    }

    @ViewBuilder private func trackMenu(_ track: Track) -> some View {
        Button { navPath?.wrappedValue.append(ArtistRef(name: album.artist)) } label: {
            Label("Go to Artist", systemImage: "music.mic")
        }
        Button { player.enqueue(track, context: tracks) } label: {
            Label("Add Track to Queue", systemImage: "text.append")
        }
        Button { editingTrack = track } label: {
            Label("Edit Tags", systemImage: "tag")
        }
    }

    // MARK: Helpers

    /// Item #4: in the album view, don't repeat the artist name on each track when
    /// it's the same as the album artist.
    private func artistMatchesAlbum(_ track: Track) -> Bool {
        guard let a = track.artist else { return true }
        return a.caseInsensitiveCompare(album.artist) == .orderedSame
    }

    /// Item #5: format + bitrate summary for the album.
    private var formatSummary: String? {
        guard !tracks.isEmpty else { return nil }
        let fmts = Set(tracks.map { $0.formatLabel })
        let fmt = fmts.count == 1 ? (fmts.first ?? "") : "Mixed"
        let brs = tracks.compactMap { $0.bitrateKbps }
        guard let lo = brs.min(), let hi = brs.max() else { return fmt }
        let br = lo == hi ? "\(lo) kbps" : "\(lo)–\(hi) kbps"
        return "\(fmt) · \(br)"
    }
}

struct TrackRow: View {
    let track: Track
    var isCurrent: Bool = false
    /// When true, the artist subtitle is suppressed (album view, same artist).
    var hideArtist: Bool = false

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
                    .fixedSize(horizontal: false, vertical: true)
                if !hideArtist, let artist = track.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
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
