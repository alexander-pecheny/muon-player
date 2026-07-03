import Foundation
import Network
import Observation

/// Bridges playback events to Last.fm. Every eligible play is written to SQLite
/// first (so nothing is lost offline), then a background loop retries pending
/// scrobbles indefinitely until Last.fm accepts them (is_scrobbled → 1).
@MainActor
@Observable
final class ScrobbleService {
    private(set) var pendingCount = 0
    private(set) var isConfigured = false

    private let database: Database
    private let client: LastFMClient
    private let monitor = NWPathMonitor()
    private var online = true
    private var flushing = false
    private var timer: Timer?

    init(database: Database, credentials: LastFMClient.Credentials) {
        self.database = database
        self.client = LastFMClient(credentials: credentials)
        self.isConfigured = credentials.isConfigured
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let nowOnline = path.status == .satisfied
                let cameOnline = nowOnline && !self.online
                self.online = nowOnline
                if cameOnline { self.flush() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.muonplayer.net"))

        // Periodic retry as a backstop (covers transient API errors, etc.).
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        Task { await refreshPendingCount(); flush() }
    }

    // MARK: - Playback hooks

    func nowPlaying(_ track: Track) {
        guard isConfigured else { return }
        let s = LastFMClient.Scrobble(
            artist: track.displayArtist, album: track.album, title: track.title,
            timestamp: Int(Date().timeIntervalSince1970),
            duration: track.duration.map { Int($0) }
        )
        Task { try? await client.updateNowPlaying(s) }
    }

    /// Called when a track stops being current. Applies Last.fm's eligibility
    /// rule and, if met, records the scrobble to SQLite (always — even offline).
    func trackFinished(_ track: Track, played: TimeInterval) {
        guard let duration = track.duration, duration > 30 else { return }
        let threshold = min(duration / 2, 240)
        guard played >= threshold else { return }

        let startedAt = Int(Date().timeIntervalSince1970 - played)
        let artist = track.displayArtist
        let album = track.album
        let title = track.title
        let dur = Int(duration)
        Task {
            await database.insertScrobble(artist: artist, album: album, title: title,
                                          timestamp: startedAt, duration: dur)
            await refreshPendingCount()
            flush()
        }
    }

    // MARK: - Retry loop

    func flush() {
        guard isConfigured, online, !flushing else { return }
        flushing = true
        Task {
            defer { flushing = false }
            await drainPending()
            await refreshPendingCount()
        }
    }

    private func drainPending() async {
        while true {
            let batch = await database.pendingScrobbles(limit: 50)
            guard !batch.isEmpty else { return }
            for row in batch {
                let s = LastFMClient.Scrobble(
                    artist: row.artist, album: row.album, title: row.title,
                    timestamp: row.timestamp, duration: row.duration
                )
                do {
                    try await client.scrobble(s)
                    await database.markScrobbled(id: row.id)
                } catch LastFMClient.LastFMError.transient {
                    return // offline / rate-limited — try again later, keep pending
                } catch {
                    // Permanent error for this row (bad metadata etc.): leave it
                    // pending but stop the pass to avoid hammering the API.
                    print("scrobble error (kept pending): \(error)")
                    return
                }
            }
        }
    }

    private func refreshPendingCount() async {
        pendingCount = await database.pendingScrobbleCount()
    }
}
