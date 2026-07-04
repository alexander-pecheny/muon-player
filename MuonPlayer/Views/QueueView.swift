import SwiftUI

struct QueueView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let current = player.currentTrack {
                    Section("Now Playing") {
                        TrackRow(track: current, isCurrent: true)
                    }
                }
                Section("Next in Queue") {
                    if player.upNext.isEmpty {
                        Text("Queue is empty").foregroundStyle(.secondary)
                    } else {
                        ForEach(player.upNext) { item in
                            TrackRow(track: item.track)
                                .swipeActions {
                                    Button(role: .destructive) {
                                        player.removeFromQueue(id: item.id)
                                    } label: { Label("Remove", systemImage: "trash") }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !player.upNext.isEmpty {
                        Button("Clear") { player.clearQueue() }
                    }
                }
            }
        }
    }
}
