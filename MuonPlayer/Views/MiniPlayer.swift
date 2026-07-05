import SwiftUI

struct MiniPlayer: View {
    @Environment(Player.self) private var player
    var onTap: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                ArtworkView(path: player.currentTrack?.url.path, cornerRadius: 6)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentTrack?.title ?? "")
                        .font(.subheadline.weight(.medium)).lineLimit(1)
                    if let artist = player.currentTrack?.artist {
                        Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()

                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.title3)
                }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title3)
                }
            }
            MiniWaveform(height: 14)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
