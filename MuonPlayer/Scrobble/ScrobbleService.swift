import Foundation
import Network
import Observation

/// Bridges playback events to Last.fm. Every eligible play is written to SQLite
/// first (so nothing is lost offline), then a background loop retries pending
/// scrobbles indefinitely until Last.fm accepts them (is_scrobbled → 1).
///
/// Also owns Last.fm login state: the user signs in with their username/password
/// (Settings tab), which is exchanged for a session key persisted across launches.
@MainActor
@Observable
final class ScrobbleService {
    private(set) var pendingCount = 0
    private(set) var username: String?
    private(set) var isBusy = false
    private(set) var lastError: String?

    var isLoggedIn: Bool { username != nil }

    private let database: Database
    private let client: LastFMClient
    private let hasAppKeys: Bool
    private let monitor = NWPathMonitor()
    private var online = true
    private var flushing = false
    private var timer: Timer?

    private let skKey = "lastfm.sessionKey"
    private let userKey = "lastfm.username"

    init(database: Database, apiKey: String, apiSecret: String) {
        self.database = database
        self.hasAppKeys = !apiKey.isEmpty && !apiSecret.isEmpty
        let storedKey = UserDefaults.standard.string(forKey: skKey)
        let storedUser = UserDefaults.standard.string(forKey: userKey)
        self.client = LastFMClient(apiKey: apiKey, apiSecret: apiSecret, sessionKey: storedKey)
        self.username = storedKey != nil ? storedUser : nil
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

    // MARK: - Login

    var canLogIn: Bool { hasAppKeys }

    @discardableResult
    func logIn(username: String, password: String) async -> Bool {
        guard hasAppKeys else { lastError = "Missing app API key/secret."; return false }
        isBusy = true; lastError = nil
        defer { isBusy = false }
        do {
            let key = try await client.authenticate(username: username, password: password)
            UserDefaults.standard.set(key, forKey: skKey)
            UserDefaults.standard.set(username, forKey: userKey)
            self.username = username
            flush()
            return true
        } catch {
            lastError = Self.describe(error)
            return false
        }
    }

    func logOut() {
        UserDefaults.standard.removeObject(forKey: skKey)
        UserDefaults.standard.removeObject(forKey: userKey)
        username = nil
        Task { await client.setSessionKey(nil) }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case LastFMClient.LastFMError.api(let code, let message):
            if code == 4 || code == 6 { return "Invalid username or password." }
            return "Last.fm error \(code): \(message)"
        case LastFMClient.LastFMError.transient:
            return "Network unavailable. Check your connection."
        case LastFMClient.LastFMError.notConfigured:
            return "Scrobbling isn’t configured (missing app API key)."
        default:
            return "Login failed. Please try again."
        }
    }

    // MARK: - Playback hooks

    func nowPlaying(_ track: Track) {
        guard isLoggedIn else { return }
        let s = LastFMClient.Scrobble(
            artist: track.displayArtist, album: track.album, title: track.title,
            timestamp: Int(Date().timeIntervalSince1970),
            duration: track.duration.map { Int($0) }
        )
        Task { try? await client.updateNowPlaying(s) }
    }

    /// Called when a track stops being current. Records it to the local play
    /// history (always) and, if it meets Last.fm's eligibility rule and the user
    /// is signed in, also queues a scrobble to SQLite (even offline).
    func trackFinished(_ track: Track, played: TimeInterval) {
        // Ignore accidental blips / rapid skips.
        guard played >= 4 else { return }

        let startedAt = Int(Date().timeIntervalSince1970 - played)
        let artist = track.displayArtist
        let album = track.album
        let title = track.title
        let path = track.url.path

        let duration = track.duration ?? 0
        let meetsRule = duration > 30 && played >= min(duration / 2, 240)
        let willScrobble = meetsRule && isLoggedIn

        Task {
            if willScrobble {
                await database.insertScrobble(artist: artist, album: album, title: title,
                                              timestamp: startedAt, duration: Int(duration))
            }
            await database.insertHistory(path: path, artist: artist, album: album, title: title,
                                         playedAt: startedAt,
                                         state: willScrobble ? .pending : .ineligible)
            if willScrobble {
                await refreshPendingCount()
                flush()
            }
        }
    }

    // MARK: - Retry loop

    func flush() {
        guard isLoggedIn, online, !flushing else { return }
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
                    await database.markHistoryScrobbled(artist: row.artist, title: row.title, playedAt: row.timestamp)
                } catch LastFMClient.LastFMError.transient {
                    return // offline / rate-limited — try again later, keep pending
                } catch {
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
