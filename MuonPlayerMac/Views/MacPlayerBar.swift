import SwiftUI

/// The persistent transport at the bottom of the window: artwork, title, a
/// scrubbable waveform, transport buttons, mode picker, volume, queue toggle.
struct MacPlayerBar: View {
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(MacRouter.self) private var router

    @State private var waveform: [Float] = []
    @State private var scrubFraction: Double?

    private var progress: Double {
        if let scrubFraction { return scrubFraction }
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.currentTime / player.duration))
    }

    private var elapsed: TimeInterval {
        scrubFraction.map { $0 * player.duration } ?? player.currentTime
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                nowPlaying
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 300, alignment: .leading)
                transport
                seekBar
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(.bar)
        .task(id: player.currentTrack?.url) {
            waveform = []
            guard let track = player.currentTrack else { return }
            waveform = await WaveformStore.shared.waveform(for: track.url, duration: player.duration)
        }
    }

    // MARK: - Pieces

    @ViewBuilder private var nowPlaying: some View {
        HStack(spacing: 9) {
            ArtworkView(path: player.currentTrack?.url.path, cornerRadius: 4)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                if let track = player.currentTrack {
                    Button { openAlbum(track) } label: {
                        Text(track.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .disabled(library.album(for: track) == nil)

                    Button { router.openArtist(track.effectiveAlbumArtist) } label: {
                        Text(track.displayArtist)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Not Playing")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func openAlbum(_ track: Track) {
        guard let album = library.album(for: track) else { return }
        router.openAlbum(album, focus: track.url.path)
    }

    private var transport: some View {
        HStack(spacing: 4) {
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17))
                    .frame(width: 26)
            }
            Button { player.next() } label: { Image(systemName: "forward.fill") }
        }
        .buttonStyle(.borderless)
        .disabled(player.currentTrack == nil)
    }

    private var seekBar: some View {
        VStack(spacing: 2) {
            WaveformSeekBar(
                samples: waveform,
                progress: progress,
                onScrub: { scrubFraction = $0 },
                onCommit: { fraction in
                    player.seek(to: fraction * player.duration)
                    scrubFraction = nil
                },
                interactive: player.currentTrack != nil,
                minBarHeight: 2,
                barWidth: 2,
                barSpacing: 1.5,
                accent: player.accentColor
            )
            .frame(height: 26)
            HStack {
                Text(formatDuration(elapsed))
                Spacer()
                Text("-" + formatDuration(max(0, player.duration - elapsed)))
            }
            .font(.system(size: 9.5).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var trailing: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Mode", selection: Binding(get: { player.mode }, set: { player.mode = $0 })) {
                    ForEach(PlaybackMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: player.mode.systemImage)
                    .foregroundStyle(player.mode == .normal ? Color.secondary : player.accentColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .help(player.mode.label)

            Button { router.showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .overlay(alignment: .topTrailing) {
                        if !player.upNext.isEmpty {
                            Circle().fill(player.accentColor)
                                .frame(width: 5, height: 5).offset(x: 3, y: -3)
                        }
                    }
            }
            .buttonStyle(.borderless)
            .help("Queue")

            Button { router.showNowPlaying.toggle() } label: {
                Image(systemName: "sidebar.trailing")
            }
            .buttonStyle(.borderless)
            .help("Now Playing")

            VolumeSlider()
        }
    }
}

private struct VolumeSlider: View {
    @Environment(Player.self) private var player

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: player.volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 13)
            Slider(value: Binding(get: { Double(player.volume) },
                                  set: { player.volume = Float($0) }), in: 0...1)
                .controlSize(.mini)
                .frame(width: 74)
        }
    }
}
