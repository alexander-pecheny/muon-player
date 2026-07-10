import SwiftUI

/// The Now Playing inspector: big artwork, metadata, what's up next.
struct MacNowPlayingView: View {
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(MacRouter.self) private var router

    var body: some View {
        Group {
            if let track = player.currentTrack {
                ScrollView { content(track) }
            } else {
                ContentUnavailableView("Not Playing", systemImage: "music.note")
            }
        }
    }

    private func content(_ track: Track) -> some View {
        VStack(spacing: 14) {
            artwork
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(radius: 10, y: 4)

            VStack(spacing: 3) {
                Button { openAlbum(track, focused: true) } label: {
                    Text(track.title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .disabled(library.album(for: track) == nil)

                Button { router.openArtist(track.effectiveAlbumArtist) } label: {
                    Text(track.displayArtist).font(.subheadline).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if let album = track.album {
                    Button { openAlbum(track, focused: false) } label: {
                        Text(album).font(.caption).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(library.album(for: track) == nil)
                }

                Text(track.formatDescription)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }

            if let next = player.nextUpTrack {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("Up Next")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ArtworkView(path: next.url.path, cornerRadius: 3)
                            .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(next.title).font(.caption).lineLimit(1)
                            Text(next.displayArtist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
    }

    @ViewBuilder private var artwork: some View {
        if let art = player.currentArtwork {
            Image(platformImage: art).resizable().aspectRatio(contentMode: .fit)
        } else {
            ArtworkView(path: player.currentTrack?.url.path, cornerRadius: 10)
        }
    }

    private func openAlbum(_ track: Track, focused: Bool) {
        guard let album = library.album(for: track) else { return }
        router.openAlbum(album, focus: focused ? track.url.path : nil)
    }
}
