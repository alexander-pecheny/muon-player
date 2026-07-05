import SwiftUI

struct NowPlayingView: View {
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(TabRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    @State private var waveform: [Float] = []
    // Non-nil only while the user is actively dragging the waveform.
    @State private var scrubFraction: Double?

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
                if let track = player.currentTrack {
                    Button { goToArtist() } label: {
                        Text(track.displayArtist)
                            .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                    if let album = track.album {
                        Button { goToAlbum() } label: {
                            Text(album).font(.subheadline).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.plain)
                        .disabled(matchingAlbum(for: track) == nil)
                    }
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
        .tint(player.accentColor)
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

    // Playback fraction, derived straight from the player every render (the single
    // source of truth), so it can never drift or stick mid-track. A live drag
    // overrides it locally.
    private var progressFraction: Double {
        if let scrubFraction { return scrubFraction }
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.currentTime / player.duration))
    }

    // Both labels derive from the same integer second so they update in lockstep.
    private var elapsedSeconds: Int {
        let time = scrubFraction.map { $0 * player.duration } ?? player.currentTime
        return Int(time.rounded(.down))
    }
    private var remainingSeconds: Int {
        max(0, Int(player.duration.rounded()) - elapsedSeconds)
    }

    private var seekBar: some View {
        VStack(spacing: 6) {
            WaveformSeekBar(
                samples: waveform,
                progress: progressFraction,
                onScrub: { scrubFraction = $0 },
                onCommit: { fraction in
                    player.seek(to: fraction * player.duration)
                    scrubFraction = nil
                },
                accent: player.accentColor
            )
            .frame(height: 48)
            HStack {
                Text(formatDuration(Double(elapsedSeconds)))
                Spacer()
                Text("-" + formatDuration(Double(remainingSeconds)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .task(id: player.currentTrack?.url) {
            waveform = []
            guard let track = player.currentTrack else { return }
            waveform = await WaveformStore.shared.waveform(for: track.url,
                                                           duration: player.duration)
        }
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

    // Playback mode dropdown + queue access.
    private var secondaryControls: some View {
        HStack {
            Menu {
                Picker("Playback Mode", selection: modeBinding) {
                    ForEach(PlaybackMode.allCases) { m in
                        Label(m.label, systemImage: m.systemImage).tag(m)
                    }
                }
            } label: {
                Label(player.mode.label, systemImage: player.mode.systemImage)
                    .font(.subheadline)
                    .foregroundStyle(player.mode == .normal ? Color.secondary : player.accentColor)
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

    private var modeBinding: Binding<PlaybackMode> {
        Binding(get: { player.mode }, set: { player.mode = $0 })
    }

    // MARK: - Navigation (item #8)

    private func goToArtist() {
        guard let track = player.currentTrack else { return }
        // Prefer the shown artist if it has its own page, else the album-artist
        // (the Artists tab groups by album-artist, so that's guaranteed to exist).
        let shown = track.displayArtist
        let name = library.albums.contains(where: { $0.artist == shown }) ? shown : track.effectiveAlbumArtist
        dismiss()
        router.openArtist(name)
    }

    private func goToAlbum() {
        guard let track = player.currentTrack, let album = matchingAlbum(for: track) else { return }
        dismiss()
        router.openAlbum(album)
    }

    private func matchingAlbum(for track: Track) -> Album? {
        guard let title = track.album else { return nil }
        return library.albums.first { $0.artist == track.effectiveAlbumArtist && $0.title == title }
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
