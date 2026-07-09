import Foundation

/// Routes playback events to the scrobbler. Both platforms' app entry points
/// call this once, after building the object graph.
@MainActor
func connectScrobbler(_ scrobbler: ScrobbleService, to player: Player) {
    player.onTrackStarted = { [scrobbler] track in scrobbler.nowPlaying(track) }
    player.onTrackFinished = { [scrobbler] track, played in scrobbler.trackFinished(track, played: played) }
    player.onScrobbleEligible = { [scrobbler] track in scrobbler.scrobbleEligible(track) }
}

@MainActor
func makeScrobbler(for library: LibraryStore) -> ScrobbleService {
    ScrobbleService(database: library.database,
                    apiKey: Secrets.lastFMApiKey,
                    apiSecret: Secrets.lastFMApiSecret)
}
