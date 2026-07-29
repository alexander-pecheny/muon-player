import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif
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
    /// Bumped after a finished play is written to the history table, so the
    /// History view can reload the moment a row actually exists (rather than
    /// racing the async insert on the next track change).
    private(set) var historyVersion = 0
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

    /// The play currently in progress. Keeps the start timestamp stable and
    /// remembers whether it was already scrobbled, so a single listen scrobbles
    /// at most once and its local-history row records the right state on finish.
    private struct PlayState { let id: UUID; let startedAt: Int; var scrobbled: Bool }
    private var play: PlayState?

    /// Whether the track playing right now has already been scrobbled this play.
    /// Observable so the History view's live row can flip to a scrobbled state.
    private(set) var currentScrobbled = false

    func nowPlaying(_ track: Track) {
        // A genuinely new track arms a fresh play; re-entry for the same track
        // (a seek or replay) keeps its start time and scrobbled flag.
        if play?.id != track.id {
            play = PlayState(id: track.id, startedAt: Int(Date().timeIntervalSince1970), scrobbled: false)
            currentScrobbled = false
        }
        guard isLoggedIn else { return }
        let s = LastFMClient.Scrobble(
            artist: track.displayArtist, album: track.album, title: track.title,
            timestamp: Int(Date().timeIntervalSince1970),
            duration: track.duration.map { Int($0) }
        )
        Task { try? await client.updateNowPlaying(s) }
    }

    /// Called mid-playback the moment the track first meets Last.fm's eligibility
    /// rule. Queues the scrobble to SQLite immediately (and flushes if online) —
    /// no longer deferred to the next track change.
    func scrobbleEligible(_ track: Track) {
        guard isLoggedIn, var p = play, p.id == track.id, !p.scrobbled else { return }
        p.scrobbled = true
        play = p
        currentScrobbled = true

        let artist = track.displayArtist
        let album = track.album
        let title = track.title
        let duration = track.duration ?? 0
        Task {
            await database.insertScrobble(artist: artist, album: album, title: title,
                                          timestamp: p.startedAt, duration: Int(duration))
            await refreshPendingCount()
            flush()
        }
    }

    /// Called when a track stops being current. Records it to the local play
    /// history. The scrobble itself (if any) was already queued mid-playback by
    /// `scrobbleEligible`, so this only reflects that outcome in the history row.
    func trackFinished(_ track: Track, played: TimeInterval) {
        // Ignore accidental blips / rapid skips.
        guard played >= 4 else { return }

        let duration = track.duration ?? 0
        // Backstop: if the mid-play eligibility emit was somehow missed but the
        // final played time qualifies, scrobble now. Idempotent — a no-op if it
        // already scrobbled or the user is signed out.
        if duration > 30, played >= min(duration / 2, 240) {
            scrobbleEligible(track)
        }

        let scrobbled = play?.id == track.id && (play?.scrobbled ?? false)
        let startedAt = play?.id == track.id ? play!.startedAt
                                             : Int(Date().timeIntervalSince1970 - played)
        if play?.id == track.id { play = nil; currentScrobbled = false }

        let artist = track.displayArtist
        let album = track.album
        let title = track.title
        let path = track.url.path

        Task {
            // Resolve the state now: the scrobble was queued mid-play and is often
            // already accepted by the time the track ends, so a plain `.pending`
            // could get stuck (markHistoryScrobbled ran before this row existed).
            let state: HistoryEntry.ScrobbleState
            if scrobbled {
                let accepted = await database.scrobbleState(artist: artist, title: title, timestamp: startedAt)
                state = accepted == true ? .scrobbled : .pending
            } else {
                state = .ineligible
            }
            await database.insertHistory(path: path, artist: artist, album: album, title: title,
                                         playedAt: startedAt, state: state,
                                         duration: duration > 0 ? Int(duration.rounded()) : nil,
                                         listened: Int(played.rounded()))
            // Row now exists — signal the History view to reload (back on the main
            // actor, since this Task inherits ScrobbleService's isolation).
            historyVersion += 1
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
