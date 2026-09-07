import SwiftUI

/// A compact, display-only waveform progress strip for the mini player. Loads
/// (and caches) the current track's waveform and fills up to the current
/// playback position. The bar count is derived from the width by WaveformSeekBar.
struct MiniWaveform: View {
    @Environment(Player.self) private var player
    @State private var waveform: [Float] = []

    /// nil fills whatever height the parent gives.
    var height: CGFloat?

    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.currentTime / player.duration))
    }

    private var samples: [Float] {
        if !waveform.isEmpty { return waveform }
        return player.currentTrack.flatMap { WaveformStore.shared.peek($0.url) } ?? []
    }

    var body: some View {
        WaveformSeekBar(samples: samples, progress: progress, interactive: false,
                        minBarHeight: 2, accent: player.accentColor)
            .frame(height: height)
            .allowsHitTesting(false)
            .task(id: player.currentTrack?.url) {
                waveform = []
                guard let track = player.currentTrack else { return }
                waveform = await WaveformStore.shared.waveform(for: track.url, duration: player.duration)
            }
    }
}
