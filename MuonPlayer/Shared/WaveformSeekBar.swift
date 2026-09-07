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
    /// spaced — never sub-pixel slivers that cluster.
    var barWidth: CGFloat = 1
    var barSpacing: CGFloat = 0
    /// Color of the played portion. Defaults to the system accent; callers pass
    /// the artwork-derived accent so the bar matches the current track.
    var accent: Color = .accentColor
    /// When set, a pointer resting on the bar shows a line and the time under it.
    var duration: TimeInterval = 0
    /// Stamp elapsed / total and the remainder on the bottom corners.
    var showsTimes = false

    @State private var dragFraction: Double?
    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let shown = dragFraction ?? progress
            let shape = WaveformShape(samples: samples, barWidth: barWidth,
                                      barSpacing: barSpacing, minBarHeight: minBarHeight)
            shape.fill(Color.secondary.opacity(0.28))
                .overlay {
                    shape.fill(accent)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: geo.size.width * shown)
                        }
                }
                .contentShape(Rectangle())
                .modifier(SeekGesture(enabled: interactive, width: geo.size.width,
                                      dragFraction: $dragFraction, onScrub: onScrub, onCommit: onCommit))
                .animation(.linear(duration: 0.12), value: shown)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hoverX = point.x
                    case .ended: hoverX = nil
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let hoverX, interactive, duration > 0 {
                        Rectangle().fill(.white.opacity(0.7)).frame(width: 1).offset(x: hoverX)
                    }
                }
                // A stamp darkens the bars under it, capsule-shaped, and nothing
                // else: white on that measures 7:1 against a light accent, where a
                // shadowed glyph managed 2:1, and off the waveform it stays bare.
                .overlay {
                    let stamps = stamps(width: geo.size.width, shown: shown)
                    shape.fill(.black.opacity(0.55))
                        .mask { stampLayer(stamps, asMask: true) }
                    stampLayer(stamps, asMask: false)
                }
        }
    }

    private struct Stamp: Identifiable {
        let text: String
        let alignment: Alignment
        let x: CGFloat
        var id: String { "\(alignment)" }
    }

    private func stamps(width: CGFloat, shown: Double) -> [Stamp] {
        guard duration > 0 else { return [] }
        var stamps: [Stamp] = []
        if showsTimes {
            let elapsed = shown * duration
            stamps.append(Stamp(text: formatDuration(elapsed) + " / " + formatDuration(duration),
                                alignment: .bottomLeading, x: 0))
            stamps.append(Stamp(text: "-" + formatDuration(max(0, duration - elapsed)),
                                alignment: .bottomTrailing, x: 0))
        }
        if let hoverX, interactive {
            stamps.append(Stamp(text: formatDuration(Double(hoverX / width) * duration),
                                alignment: .topLeading, x: min(max(0, hoverX - 22), width - 44)))
        }
        return stamps
    }

    private func stampLayer(_ stamps: [Stamp], asMask: Bool) -> some View {
        ZStack {
            ForEach(stamps) { stamp in
                Text(stamp.text)
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(asMask ? .clear : .white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(asMask ? Capsule().fill(.black) : nil)
                    .fixedSize()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: stamp.alignment)
                    .offset(x: stamp.x)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The waveform itself: one vertical bar per column, centred on the midline.
/// Drawn as a single path so a thousand columns cost two fills rather than a
/// thousand animated views.
struct WaveformShape: Shape {
    let samples: [Float]
    var barWidth: CGFloat = 1
    var barSpacing: CGFloat = 0
    var minBarHeight: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        let slot = barWidth + barSpacing
        let count = max(1, Int(rect.width / slot))
        let bars = resampled(to: count)
        var path = Path()
        // Columns that touch are drawn as one envelope through their peaks: a
        // sloped edge is antialiased, a staircase of rectangles is not.
        if barSpacing == 0 {
            let tops = bars.enumerated().map { i, bar in
                CGPoint(x: rect.minX + (CGFloat(i) + 0.5) * barWidth,
                        y: rect.midY - max(minBarHeight, CGFloat(bar) * rect.height) / 2)
            }
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            for point in tops { path.addLine(to: point) }
            path.addLine(to: CGPoint(x: rect.minX + CGFloat(count) * barWidth, y: rect.midY))
            for point in tops.reversed() { path.addLine(to: CGPoint(x: point.x, y: 2 * rect.midY - point.y)) }
            path.closeSubpath()
            return path
        }
        for (i, bar) in bars.enumerated() {
            let height = max(minBarHeight, CGFloat(bar) * rect.height)
            path.addRect(CGRect(x: rect.minX + CGFloat(i) * slot, y: rect.midY - height / 2,
                                width: barWidth, height: height))
        }
        return path
    }

    /// Max-pool when there is more data than columns, repeat when there is less
    /// (a flat placeholder when there is none).
    private func resampled(to count: Int) -> [Float] {
        guard !samples.isEmpty else { return Array(repeating: 0.12, count: count) }
        guard samples.count < count else { return WaveformStore.downsample(samples, to: count) }
        return (0..<count).map { samples[$0 * samples.count / count] }
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
