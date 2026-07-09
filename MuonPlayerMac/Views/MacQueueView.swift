import SwiftUI

struct MacQueueView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Queue").font(.headline)
                Spacer()
                if !player.upNext.isEmpty {
                    Button("Clear") { player.clearQueue() }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)

            Divider()

            List {
                if let current = player.currentTrack {
                    Section("Now Playing") {
                        MacTrackRow(track: current, context: [current], showArtwork: true)
                    }
                }
                Section("Next in Queue") {
                    if player.upNext.isEmpty {
                        Text("Queue is empty").foregroundStyle(.secondary)
                    } else {
                        ForEach(player.upNext) { item in
                            HStack {
                                MacTrackRow(track: item.track, context: [item.track], showArtwork: true)
                                Button {
                                    player.removeFromQueue(id: item.id)
                                } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 460, height: 480)
    }
}
