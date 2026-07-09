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
    @State private var editing = false

    private var isCurrent: Bool { player.currentTrack?.url == track.url }

    var body: some View {
        HStack(spacing: 9) {
            if showNumber {
                Group {
                    if isCurrent {
                        Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                            .foregroundStyle(player.accentColor)
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
                    .foregroundStyle(isCurrent ? player.accentColor : .primary)
                if showArtwork {
                    Text("\(track.displayArtist) — \(track.displayAlbum)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
            Button("Edit Tags…") { editing = true }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([track.url])
            }
        }
        .sheet(isPresented: $editing) { MacTagEditView(scope: .track(track)) }
    }
}
