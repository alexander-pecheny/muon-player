import SwiftUI

/// Unlimited local play history with each play's Last.fm scrobble outcome.
struct MacHistoryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @Environment(ScrobbleService.self) private var scrobbler
    @State private var entries: [HistoryEntry] = []

    var body: some View {
        List(entries) { entry in
            HStack(spacing: 12) {
                icon(entry.scrobbleState).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).lineLimit(1)
                    Text(entry.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let listened = entry.listened {
                    Text(formatDuration(Double(listened)))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Text(Self.relative(entry.playedAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 70, alignment: .trailing)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock",
                                       description: Text("Tracks you play appear here with their scrobble status."))
            }
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem { Button { Task { await reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
        }
        .task(id: player.currentTrack?.id) { await reload() }
        .onChange(of: scrobbler.historyVersion) { Task { await reload() } }
        .onChange(of: scrobbler.pendingCount) { Task { await reload() } }
    }

    private func reload() async { entries = await library.history() }

    @ViewBuilder private func icon(_ state: HistoryEntry.ScrobbleState) -> some View {
        switch state {
        case .scrobbled:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .pending:
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
        case .ineligible:
            Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        }
    }

    private static func relative(_ unix: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}
