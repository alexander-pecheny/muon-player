import SwiftUI

struct FileListView: View {
    @Environment(AudioEngine.self) private var audioEngine
    @State private var tracks: [Track] = []
    @State private var isLoading = false
    private let scanner = FileScanner()

    var body: some View {
        List(tracks) { track in
            Button {
                audioEngine.play(track: track, playlist: tracks)
            } label: {
                TrackRow(track: track, isCurrentTrack: audioEngine.currentTrack?.id == track.id)
            }
        }
        .overlay {
            if tracks.isEmpty && !isLoading {
                ContentUnavailableView(
                    "No Music Files",
                    systemImage: "music.note",
                    description: Text("Add audio files to the Muon Player folder in the Files app.")
                )
            }
        }
        .refreshable {
            await loadTracks()
        }
        .task {
            await loadTracks()
        }
    }

    private func loadTracks() async {
        isLoading = true
        tracks = await scanner.scan()
        isLoading = false
    }
}

private struct TrackRow: View {
    let track: Track
    let isCurrentTrack: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .foregroundStyle(isCurrentTrack ? Color.accentColor : .primary)

                if let artist = track.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let duration = track.duration {
                Text(formatDuration(duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
