import SwiftUI

struct NowPlayingView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var seekPosition: Double = 0
    @State private var isSeeking = false
    @State private var showQueue = false

    var body: some View {
        VStack(spacing: 20) {
            Capsule().fill(.secondary).frame(width: 40, height: 5).padding(.top, 8)

            artwork
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 340)
                .shadow(radius: 16, y: 8)
                .padding(.horizontal)

            VStack(spacing: 4) {
                Text(player.currentTrack?.title ?? "Not Playing")
                    .font(.title2.bold()).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(player.currentTrack?.displayArtist ?? "")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let album = player.currentTrack?.album {
                    Text(album).font(.subheadline).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let fmt = player.currentTrack?.formatDescription {
                    Text(fmt).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal)

            seekBar
            controls
            secondaryControls
            nextUp

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

    // Both labels derive from the same integer second so they update in lockstep
    // (otherwise elapsed and remaining tick at different sub-second offsets).
    private var elapsedSeconds: Int {
        Int((isSeeking ? seekPosition : player.currentTime).rounded(.down))
    }
    private var remainingSeconds: Int {
        max(0, Int(player.duration.rounded()) - elapsedSeconds)
    }

    // Single-source-of-truth slider. Binding is never swapped mid-gesture (which
    // used to drop the editing-ended event and freeze the bar until reopened).
    private var seekBar: some View {
        VStack(spacing: 2) {
            Slider(value: $seekPosition, in: 0...max(player.duration, 1)) { editing in
                if editing {
                    isSeeking = true
                } else {
                    player.seek(to: seekPosition)
                    isSeeking = false
                }
            }
            .onChange(of: player.currentTime) { _, newValue in
                if !isSeeking { seekPosition = newValue }
            }
            .onChange(of: player.currentTrack?.id) { _, _ in
                if !isSeeking { seekPosition = player.currentTime }
            }
            HStack {
                Text(formatDuration(Double(elapsedSeconds)))
                Spacer()
                Text("-" + formatDuration(Double(remainingSeconds)))
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

    // Item #8: shuffle / repeat mode + queue access.
    private var secondaryControls: some View {
        HStack {
            Button { player.mode = player.mode.next } label: {
                Label(player.mode.label, systemImage: player.mode.systemImage)
                    .font(.subheadline)
                    .foregroundStyle(player.mode == .normal ? Color.secondary : Color.accentColor)
            }
            Spacer()
            Button { showQueue = true } label: {
                Label(player.upNext.isEmpty ? "Queue" : "Queue (\(player.upNext.count))",
                      systemImage: "list.bullet")
                    .font(.subheadline)
            }
        }
        .padding(.horizontal, 28)
    }

    // Item #10: what's coming next (explicit queue head, else playhead's next).
    @ViewBuilder private var nextUp: some View {
        if let next = player.nextUpTrack {
            HStack(spacing: 6) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.caption2).foregroundStyle(.tertiary)
                Text("Next: ").foregroundStyle(.tertiary)
                + Text(next.title).foregroundStyle(.secondary)
                + Text(next.artist.map { " — \($0)" } ?? "").foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 28)
        }
    }
}
