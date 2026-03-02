import SwiftUI

struct NowPlayingView: View {
    @Environment(AudioEngine.self) private var audioEngine
    @State private var seekPosition: Double = 0
    @State private var isSeeking = false

    var body: some View {
        VStack(spacing: 8) {
            // Track info
            if let track = audioEngine.currentTrack {
                VStack(spacing: 2) {
                    Text(track.title)
                        .font(.headline)
                        .lineLimit(1)

                    if let artist = track.artist {
                        Text(artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            // Seek slider
            VStack(spacing: 4) {
                Slider(
                    value: isSeeking ? $seekPosition : .constant(audioEngine.currentTime),
                    in: 0...max(audioEngine.duration, 1)
                ) { editing in
                    if editing {
                        isSeeking = true
                        seekPosition = audioEngine.currentTime
                    } else {
                        audioEngine.seek(to: seekPosition)
                        isSeeking = false
                    }
                }

                HStack {
                    Text(formatTime(isSeeking ? seekPosition : audioEngine.currentTime))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    Spacer()

                    Text(formatTime(audioEngine.duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            // Playback controls
            HStack(spacing: 40) {
                Button { audioEngine.previous() } label: {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                }

                Button {
                    if audioEngine.isPlaying {
                        audioEngine.pause()
                    } else {
                        audioEngine.resume()
                    }
                } label: {
                    Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                }

                Button { audioEngine.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
