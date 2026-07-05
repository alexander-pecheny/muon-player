import SwiftUI

/// A waveform scrubber. The played portion is filled with the accent color; the
/// rest is dimmed. Dragging (or tapping) anywhere scrubs. The displayed position
/// is derived from `progress` on every render (single source of truth), so it
/// never desyncs from playback — only an in-progress drag overrides it.
struct WaveformSeekBar: View {
    /// Normalized peak samples (0...1). Empty renders a flat placeholder.
    let samples: [Float]
    /// Current playback fraction (0...1).
    let progress: Double
    /// Called continuously while dragging with the previewed fraction.
    var onScrub: (Double) -> Void = { _ in }
    /// Called when the drag ends with the final fraction to seek to.
    var onCommit: (Double) -> Void = { _ in }
    /// When false the bar is display-only (no scrubbing) — used in the mini player.
    var interactive: Bool = true
    var minBarHeight: CGFloat = 3
    /// Each bar is drawn this wide and this far apart. The number of bars is
    /// derived from the available width so bars are always crisp and evenly
    /// spaced (SoundCloud-style) — never sub-pixel slivers that cluster.
    var barWidth: CGFloat = 3
    var barSpacing: CGFloat = 2
    /// Color of the played portion. Defaults to the system accent; callers pass
    /// the artwork-derived accent so the bar matches the current track.
    var accent: Color = .accentColor

    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { geo in
            let shown = dragFraction ?? progress
            // How many whole bar+gap slots fit the width.
            let slot = barWidth + barSpacing
            let count = max(1, Int((geo.size.width + barSpacing) / slot))
            let bars = resampled(to: count)
            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(bars.indices, id: \.self) { i in
                    // A bar is "played" once the playhead passes its center.
                    let center = (Double(i) + 0.5) / Double(count)
                    Capsule()
                        .fill(center <= shown ? accent : Color.secondary.opacity(0.28))
                        .frame(width: barWidth,
                               height: max(minBarHeight, CGFloat(bars[i]) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .modifier(SeekGesture(enabled: interactive, width: geo.size.width,
                                  dragFraction: $dragFraction, onScrub: onScrub, onCommit: onCommit))
            .animation(.linear(duration: 0.12), value: shown)
        }
    }

    /// Resample the peaks to exactly `count` bars (a flat placeholder if empty).
    private func resampled(to count: Int) -> [Float] {
        guard !samples.isEmpty else { return Array(repeating: 0.12, count: count) }
        return WaveformStore.downsample(samples, to: count)
    }
}

/// Attaches the scrub drag gesture only when interactive, so a display-only bar
/// (mini player) doesn't swallow taps meant to open the Now Playing view.
private struct SeekGesture: ViewModifier {
    let enabled: Bool
    let width: CGFloat
    @Binding var dragFraction: Double?
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let f = fraction(value.location.x)
                        dragFraction = f
                        onScrub(f)
                    }
                    .onEnded { value in
                        let f = fraction(value.location.x)
                        dragFraction = nil
                        onCommit(f)
                    }
            )
        } else {
            content
        }
    }

    private func fraction(_ x: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(1, max(0, Double(x / width)))
    }
}
