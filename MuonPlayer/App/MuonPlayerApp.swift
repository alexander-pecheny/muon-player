import SwiftUI
import AVFoundation

@main
struct MuonPlayerApp: App {
    @State private var library: LibraryStore
    @State private var player = Player()
    @State private var scrobbler: ScrobbleService

    init() {
        Self.configureAudioSession()

        // Build the object graph. LibraryStore owns the database; the scrobbler
        // shares it so scrobbles land in the same SQLite file.
        let lib = LibraryStore()
        let credentials = LastFMClient.Credentials(
            apiKey: Secrets.lastFMApiKey,
            apiSecret: Secrets.lastFMApiSecret,
            username: Secrets.lastFMUsername,
            password: Secrets.lastFMPassword
        )
        _library = State(initialValue: lib)
        _scrobbler = State(initialValue: ScrobbleService(database: lib.database, credentials: credentials))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(player)
                .environment(scrobbler)
                .task {
                    // Route playback events to the scrobbler.
                    player.onTrackStarted = { [scrobbler] track in
                        scrobbler.nowPlaying(track)
                    }
                    player.onTrackFinished = { [scrobbler] track, played in
                        scrobbler.trackFinished(track, played: played)
                    }
                    scrobbler.start()
                    await library.loadFromDatabase()
                    await library.rescan()

                    if GaplessSelfTest.isEnabled {
                        await GaplessSelfTest.run(player: player, library: library)
                    }
                    if ScrobbleSelfTest.isEnabled {
                        await ScrobbleSelfTest.run(scrobbler: scrobbler, database: library.database)
                    }
                    if ArtworkSelfTest.isEnabled {
                        await ArtworkSelfTest.run(library: library)
                    }
                }
        }
    }

    private static func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
}
