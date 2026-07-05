import SwiftUI

/// Unlimited local play history with each play's Last.fm scrobble outcome.
struct HistoryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @State private var entries: [HistoryEntry] = []

    var body: some View {
        List {
            ForEach(entries) { entry in
                HStack(spacing: 12) {
                    scrobbleIcon(entry.scrobbleState)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(entry.artist)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let listen = listenLabel(entry) {
                            Text(listen)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(Self.relative(entry.playedAt))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock",
                                       description: Text("Tracks you play appear here with their scrobble status."))
            }
        }
        .refreshable { await reload() }
        // Reload whenever the current track changes (new plays get recorded).
        .task(id: player.currentTrack?.id) { await reload() }
    }

    private func reload() async {
        entries = await library.history()
    }

    /// "1:47 of 3:52 listened" — how long the user actually spent on the track vs
    /// its length. Older rows without this data show nothing.
    private func listenLabel(_ entry: HistoryEntry) -> String? {
        switch (entry.listened, entry.duration) {
        case let (listened?, length?):
            return "\(formatDuration(Double(listened))) of \(formatDuration(Double(length))) listened"
        case let (listened?, nil):
            return "\(formatDuration(Double(listened))) listened"
        default:
            return nil
        }
    }

    @ViewBuilder private func scrobbleIcon(_ state: HistoryEntry.ScrobbleState) -> some View {
        switch state {
        case .scrobbled:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .pending:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
        case .ineligible:
            Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        }
    }

    private static let fmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func relative(_ unix: Int) -> String {
        fmt.localizedString(for: Date(timeIntervalSince1970: TimeInterval(unix)), relativeTo: Date())
    }
}
