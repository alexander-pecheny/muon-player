import SwiftUI

/// One track in a list. Double-click plays; the context menu enqueues and edits
/// tags. The trailing columns (folder, format, bitrate, duration) are what let
/// you tell two rips of the same album apart.
struct MacTrackRow: View {
    let track: Track
    var context: [Track]
    var showArtwork = false
    var showNumber = false
    var showFolder = true

    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(MacRouter.self) private var router
    @Environment(\.artworkAccent) private var accent
    @State private var editing = false

    private var isCurrent: Bool { player.currentTrack?.url == track.url }
    private var album: Album? { library.album(for: track) }

    var body: some View {
        HStack(spacing: 9) {
            if showNumber {
                Group {
                    if isCurrent {
                        Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                            .foregroundStyle(accent)
                    } else if let n = track.trackNo {
                        Text("\(n)").foregroundStyle(.secondary)
                    }
                }
                .font(.caption.monospacedDigit())
                .frame(width: 20, alignment: .trailing)
            }

            if showArtwork {
                ArtworkView(path: track.url.path, cornerRadius: 3)
                    .frame(width: 30, height: 30)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? accent : .primary)
                if showArtwork {
                    HStack(spacing: 4) {
                        Button { router.openArtist(track.effectiveAlbumArtist) } label: {
                            Text(track.displayArtist).lineLimit(1)
                        }
                        Text("—")
                        Button { openAlbum() } label: { Text(track.displayAlbum).lineLimit(1) }
                            .disabled(album == nil)
                    }
                    .buttonStyle(.plain)
                    .font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if showFolder {
                Text(library.relativeFolder(for: track))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(minWidth: 90, idealWidth: 200, maxWidth: 280, alignment: .trailing)
                    .help(track.url.deletingLastPathComponent().path)
            }

            Text(track.formatLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)

            Text(track.bitrateKbps.map { "\($0) kbps" } ?? "—")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .trailing)

            Text(track.duration.map(formatDuration) ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { player.play(track: track, context: context) }
        .contextMenu {
            Button("Play") { player.play(track: track, context: context) }
            Button("Add to Queue") { player.enqueue(track, context: context) }
            Divider()
            Button("Go to Artist") { router.openArtist(track.effectiveAlbumArtist) }
            Button("Go to Album") { openAlbum() }.disabled(album == nil)
            Divider()
            Button("Edit Tags…") { editing = true }
            RevealInFinderButton(url: track.url)
        }
        .sheet(isPresented: $editing) { MacTagEditView(scope: .track(track)) }
    }

    private func openAlbum() {
        guard let album else { return }
        router.openAlbum(album, focus: track.url.path)
    }
}
