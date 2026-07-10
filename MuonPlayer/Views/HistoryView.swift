import SwiftUI

/// Unlimited local play history with each play's Last.fm scrobble outcome.
struct HistoryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @Environment(ScrobbleService.self) private var scrobbler
    @Environment(\.navPath) private var navPath
    @State private var entries: [HistoryEntry] = []

    var body: some View {
        List {
            // The track playing right now, updating live above the finished plays.
            if let track = player.currentTrack {
                nowPlayingRow(track)
            }
            ForEach(entries) { entry in
                HStack(spacing: 12) {
                    scrobbleIcon(entry.scrobbleState)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Button { open(entry.path, artist: false) } label: {
                            Text(entry.title)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.plain)
                        .disabled(entry.path == nil)
                        Button { open(entry.path, artist: true) } label: {
                            Text(entry.artist)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.plain)
                        .disabled(entry.path == nil)
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
            if entries.isEmpty && player.currentTrack == nil {
                ContentUnavailableView("No History", systemImage: "clock",
                                       description: Text("Tracks you play appear here with their scrobble status."))
            }
        }
        .refreshable { await reload() }
        // Reload whenever the current track changes (new plays get recorded)…
        .task(id: player.currentTrack?.id) { await reload() }
        // …when a finished play is recorded (so the just-ended track appears
        // immediately, without a tab switch)…
        .onChange(of: scrobbler.historyVersion) { Task { await reload() } }
        // …and when a scrobble is accepted, so rows flip pending → scrobbled.
        .onChange(of: scrobbler.pendingCount) { Task { await reload() } }
    }

    /// Live entry for the current track: the "listened" counter ticks up in real
    /// time and the icon reflects whether it will (or already did) scrobble.
    @ViewBuilder private func nowPlayingRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            liveIcon(track).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Button { open(track.url.path, artist: false) } label: {
                    Text(track.title)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                Button { open(track.url.path, artist: true) } label: {
                    Text(track.displayArtist)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                Text(liveListenLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Text("now")
                .font(.caption).foregroundStyle(player.accentColor)
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

    /// History stores the scrobbled artist name, which is the track artist and may
    /// be no artist page at all — so resolve the row back to its file and take the
    /// album (and its album-artist) from the library.
    private func open(_ path: String?, artist: Bool) {
        guard let path, let navPath else { return }
        Task {
            guard let album = await library.album(containingPath: path) else { return }
            if artist {
                navPath.wrappedValue.append(ArtistRef(name: album.artist))
            } else {
                navPath.wrappedValue.append(AlbumRef(album: album, focusPath: path))
            }
        }
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
