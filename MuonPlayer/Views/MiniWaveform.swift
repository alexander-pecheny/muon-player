import SwiftUI

/// A compact, display-only waveform progress strip for the mini player. Loads
/// (and caches) the current track's waveform and fills up to the current
/// playback position. The bar count is derived from the width by WaveformSeekBar.
struct MiniWaveform: View {
    @Environment(Player.self) private var player
    @State private var waveform: [Float] = []

    var height: CGFloat = 14
    var barWidth: CGFloat = 2
    var barSpacing: CGFloat = 1.5

    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.currentTime / player.duration))
    }

    var body: some View {
        WaveformSeekBar(samples: waveform, progress: progress, interactive: false,
                        minBarHeight: 2, barWidth: barWidth, barSpacing: barSpacing)
            .frame(height: height)
            .allowsHitTesting(false)
            .task(id: player.currentTrack?.url) {
                waveform = []
                guard let track = player.currentTrack else { return }
                waveform = await WaveformStore.shared.waveform(for: track.url, duration: player.duration)
            }
    }
}
