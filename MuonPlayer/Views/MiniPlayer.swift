import SwiftUI

/// The mini player's row, shared by the pre-26 bar and the iOS 26 bottom
/// accessory: cover on the left, then the waveform over the full remaining
/// height with the text and transport controls laid on top of it.
struct MiniPlayerContent: View {
    @Environment(Player.self) private var player
    var cornerRadius: CGFloat = 6
    var onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            artwork
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            MiniWaveform {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(player.currentTrack?.title ?? "")
                            .font(.subheadline.weight(.medium)).lineLimit(1)
                        if let artist = player.currentTrack?.artist {
                            Text(artist).font(.caption).lineLimit(1).opacity(0.85)
                        }
                    }
                    .foregroundStyle(Color(.label))
                    Spacer(minLength: 4)
                    controls
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(maxHeight: .infinity)
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            Button { player.next() } label: { Image(systemName: "forward.fill") }
        }
        .font(.title3)
    }

    @ViewBuilder private var artwork: some View {
        if let art = player.currentArtwork {
            Image(platformImage: art).resizable().scaledToFill()
        } else {
            ArtworkView(path: player.currentTrack?.url.path, cornerRadius: cornerRadius)
        }
    }
}

struct MiniPlayer: View {
    var onTap: () -> Void

    var body: some View {
        MiniPlayerContent(onTap: onTap)
            .frame(height: 52)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Divider() }
    }
}

/// The iOS 26 tab-view bottom accessory, which provides its own glass
/// background and sets the height.
struct MiniAccessory: View {
    var onTap: () -> Void

    var body: some View {
        MiniPlayerContent(cornerRadius: 5, onTap: onTap)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }
}
