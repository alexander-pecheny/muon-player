import SwiftUI

struct NowPlayingView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var seekPosition: Double = 0
    @State private var isSeeking = false
    @State private var showQueue = false

    var body: some View {
        VStack(spacing: 24) {
            Capsule().fill(.secondary).frame(width: 40, height: 5).padding(.top, 8)

            artwork
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 340)
                .shadow(radius: 16, y: 8)
                .padding(.horizontal)

            VStack(spacing: 4) {
                Text(player.currentTrack?.title ?? "Not Playing")
                    .font(.title2.bold()).lineLimit(2).multilineTextAlignment(.center)
                Text(player.currentTrack?.displayArtist ?? "")
                    .font(.title3).foregroundStyle(.secondary).lineLimit(1)
                if let album = player.currentTrack?.album {
                    Text(album).font(.subheadline).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .padding(.horizontal)

            seekBar
            controls

            Button { showQueue = true } label: {
                Label(player.upNext.isEmpty ? "Queue" : "Queue (\(player.upNext.count))",
                      systemImage: "list.bullet")
            }
            .buttonStyle(.bordered)

            Spacer(minLength: 0)
        }
        .padding(.bottom)
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $showQueue) { QueueView() }
    }

    @ViewBuilder private var artwork: some View {
        if let art = player.currentArtwork {
            Image(uiImage: art).resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            ArtworkView(path: player.currentTrack?.url.path, cornerRadius: 16)
        }
    }

    private var seekBar: some View {
        VStack(spacing: 2) {
            Slider(
                value: isSeeking ? $seekPosition : .constant(player.currentTime),
                in: 0...max(player.duration, 1)
            ) { editing in
                if editing {
                    isSeeking = true
                    seekPosition = player.currentTime
                } else {
                    player.seek(to: seekPosition)
                    isSeeking = false
                }
            }
            HStack {
                Text(formatDuration(isSeeking ? seekPosition : player.currentTime))
                Spacer()
                Text("-" + formatDuration(max(0, player.duration - (isSeeking ? seekPosition : player.currentTime))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private var controls: some View {
        HStack(spacing: 44) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
        }
        .foregroundStyle(.primary)
    }
}
