import SwiftUI

/// The mini player's display-only waveform, with the row's text and controls
/// laid over it. Bars under the label's outline take the glass's own colour,
/// so the words read on any accent, and where the music is quiet there is
/// nothing to recolour and the label sits bare.
struct MiniWaveform<Label: View>: View {
    @Environment(Player.self) private var player
    @Environment(\.colorScheme) private var colorScheme
    @State private var waveform: [Float] = []

    /// nil fills whatever height the parent gives.
    var height: CGFloat?
    @ViewBuilder var label: () -> Label

    private static var ring: [CGSize] {
        [(2.5, 0), (-2.5, 0), (0, 2.5), (0, -2.5), (1.8, 1.8), (1.8, -1.8), (-1.8, 1.8), (-1.8, -1.8)]
            .map { CGSize(width: $0.0, height: $0.1) }
    }

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
            .overlay {
                WaveformShape(samples: samples, minBarHeight: 2)
                    .fill(colorScheme == .dark ? Color.black : .white)
                    .opacity(0.55)
                    .mask { contour }
                label()
            }
            .task(id: player.currentTrack?.url) {
                waveform = []
                guard let track = player.currentTrack else { return }
                waveform = await WaveformStore.shared.waveform(for: track.url, duration: player.duration)
            }
    }

    /// The label grown by two and a half points in every direction, plus a soft edge.
    private var contour: some View {
        ZStack {
            ForEach(Array(Self.ring.enumerated()), id: \.offset) { _, offset in
                label().offset(offset)
            }
            label().blur(radius: 5)
        }
    }
}
