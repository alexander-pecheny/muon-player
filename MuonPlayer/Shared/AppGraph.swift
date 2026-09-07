import Foundation

/// Routes playback events to the scrobbler. Both platforms' app entry points
/// call this once, after building the object graph.
@MainActor
func connectScrobbler(_ scrobbler: ScrobbleService, to player: Player) {
    player.onTrackStarted = { [scrobbler] track in scrobbler.nowPlaying(track) }
    player.onTrackFinished = { [scrobbler] track, played in scrobbler.trackFinished(track, played: played) }
    player.onScrobbleEligible = { [scrobbler] track in scrobbler.scrobbleEligible(track) }
    player.onTrackProgress = { [scrobbler] track, played, position in
        scrobbler.progressed(track, played: played, position: position)
    }
}

/// Bring the last played track back, paused where it was, so a launch does not
/// start from an empty player.
@MainActor
func restoreLastPlayed(_ player: Player, from library: LibraryStore) async {
    guard player.currentTrack == nil,
          let last = await library.history(limit: 1).first, let path = last.path,
          let album = await library.album(containingPath: path) else { return }
    let tracks = await library.tracks(in: album)
    guard let track = tracks.first(where: { $0.url.path == path }) else { return }
    var position = TimeInterval(last.position ?? 0)
    if let duration = track.duration, position >= duration - 1 { position = 0 }
    player.restore(track: track, context: tracks, at: position)
}

@MainActor
func makeScrobbler(for library: LibraryStore) -> ScrobbleService {
    ScrobbleService(database: library.database,
                    apiKey: Secrets.lastFMApiKey,
                    apiSecret: Secrets.lastFMApiSecret)
}
