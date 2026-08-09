import SwiftUI

struct NowPlayingView: View {
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(TabRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    @State private var showModePicker = false
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
                if let track = player.currentTrack {
                    Button { goToAlbum(focus: track.url.path) } label: {
                        Text(track.title)
                            .font(.title2.bold()).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(matchingAlbum(for: track) == nil)
                } else {
                    Text("Not Playing")
                        .font(.title2.bold()).multilineTextAlignment(.center)
                }
                if let track = player.currentTrack {
                    Button { goToArtist() } label: {
                        Text(track.displayArtist)
                            .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                    if let album = track.album {
                        Button { goToAlbum(focus: nil) } label: {
                            Text(album).font(.subheadline).tertiaryForeground().multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.plain)
                        .disabled(matchingAlbum(for: track) == nil)
                    }
                }
                if let fmt = player.currentTrack?.formatDescription {
                    Text(fmt).font(.caption.tabularDigits).tertiaryForeground()
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
            Image(platformImage: art).resizable().aspectRatio(contentMode: .fit)
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
            .font(.caption.tabularDigits)
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

    // Playback mode picker + queue access. The mode picker is a bottom action
    // sheet, not a Menu: a Menu anchored this low opens its tall platter upward
    // over the artwork and title with inconsistent placement (looks glitchy).
    private var secondaryControls: some View {
        HStack {
            Button { showModePicker = true } label: {
                Label(player.mode.label, systemImage: player.mode.systemImage)
                    .font(.subheadline)
                    .foregroundStyle(player.mode == .normal ? Color.secondary : player.accentColor)
            }
            .buttonStyle(.plain)
            Spacer()
            Button { showQueue = true } label: {
                Label(player.upNext.isEmpty ? "Queue" : "Queue (\(player.upNext.count))",
                      systemImage: "list.bullet")
                    .font(.subheadline)
            }
        }
        .padding(.horizontal, 28)
        .confirmationDialog("Playback Mode", isPresented: $showModePicker, titleVisibility: .visible) {
            ForEach(PlaybackMode.allCases) { m in
                Button {
                    player.mode = m
                } label: {
                    Text(m == player.mode ? "\(m.label) ✓" : m.label)
                }
            }
        }
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

    private func goToAlbum(focus: String?) {
        guard let track = player.currentTrack, let album = matchingAlbum(for: track) else { return }
        dismiss()
        router.openAlbum(album, focus: focus)
    }

    private func matchingAlbum(for track: Track) -> Album? {
        library.album(for: track)
    }

    // Item #10: what's coming next (explicit queue head, else playhead's next).
    @ViewBuilder private var nextUp: some View {
        if let next = player.nextUpTrack {
            HStack(spacing: 6) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.caption2).tertiaryForeground()
                // Three runs in a row rather than one concatenated Text: SkipSwiftUI
                // has no `+` on Text, and an HStack with no spacing reads the same.
                HStack(spacing: 0) {
                    Text("Next: ").tertiaryForeground()
                    Text(next.title).foregroundStyle(.secondary)
                    if let artist = next.artist {
                        Text(" — \(artist)").tertiaryForeground()
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 28)
        }
    }
}
