import SwiftUI

/// Unlimited local play history with each play's Last.fm scrobble outcome.
struct MacHistoryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @Environment(MacRouter.self) private var router
    @Environment(ScrobbleService.self) private var scrobbler
    @State private var entries: [HistoryEntry] = []

    var body: some View {
        List {
            // The track playing right now, updating live above the finished plays.
            if let track = player.currentTrack {
                row(title: track.title, artist: track.displayArtist, path: track.url.path,
                    listened: liveListenLabel) {
                    liveIcon(track)
                } trailing: {
                    Text("now").font(.caption).foregroundStyle(player.accentColor)
                }
            }
            ForEach(entries) { entry in
                row(title: entry.title, artist: entry.artist, path: entry.path,
                    listened: listenLabel(entry)) {
                    icon(entry.scrobbleState)
                } trailing: {
                    Text(Self.relative(entry.playedAt))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if entries.isEmpty && player.currentTrack == nil {
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

    private func row<Icon: View, Trailing: View>(
        title: String,
        artist: String,
        path: String?,
        listened: String?,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            icon().frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Button { open(path, artist: false) } label: { Text(title).lineLimit(1) }
                    .buttonStyle(.plain)
                    .disabled(path == nil)
                Button { open(path, artist: true) } label: {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled(path == nil)
                if let listened {
                    Text(listened).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            trailing().frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    /// History stores the scrobbled artist name, which is the track artist and may
    /// be no artist page at all — so resolve the row back to its file and take the
    /// album (and its album-artist) from the library.
    private func open(_ path: String?, artist: Bool) {
        guard let path else { return }
        Task {
            guard let album = await library.album(containingPath: path) else { return }
            if artist { router.openArtist(album.artist) } else { router.openAlbum(album, focus: path) }
        }
    }

    private func reload() async { entries = await library.history() }

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

    private var liveListenLabel: String {
        let pos = max(0, player.currentTime)
        if player.duration > 0 {
            return "\(formatDuration(pos)) of \(formatDuration(player.duration)) listened"
        }
        return "\(formatDuration(pos)) listened"
    }

    /// Icon for the live row: green once actually scrobbled, accent pulse while
    /// playing toward the threshold, gray when it won't scrobble (signed out / <30s).
    @ViewBuilder private func liveIcon(_ track: Track) -> some View {
        if scrobbler.currentScrobbled {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if scrobbler.isLoggedIn, player.duration > 30 {
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(player.accentColor)
        } else {
            Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        }
    }

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
