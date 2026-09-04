import SwiftUI
import AVFoundation

@main
struct MuonPlayerApp: App {
    @State private var library: LibraryStore
    @State private var player = Player()
    @State private var scrobbler: ScrobbleService
    @State private var tabSettings = TabSettings()
    @State private var router = TabRouter()
    @State private var receiver = TransferReceiver()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Self.configureAudioSession()

        // Build the object graph. LibraryStore owns the database; the scrobbler
        // shares it so scrobbles land in the same SQLite file.
        let lib = LibraryStore()
        _library = State(initialValue: lib)
        _scrobbler = State(initialValue: ScrobbleService(
            database: lib.database,
            apiKey: Secrets.lastFMApiKey,
            apiSecret: Secrets.lastFMApiSecret
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(player)
                .environment(scrobbler)
                .environment(tabSettings)
                .environment(router)
                .environment(receiver)
                // Music arrives through the Files app, which means it arrives while
                // this app is in the background. Coming back to the front is the
                // moment to look.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        library.rescanOnActivation()
                        // A suspended app loses its listener; starting is idempotent.
                        receiver.start()
                    }
                }
                .task {
                    // Let the playhead reach the library for artist-folder order.
                    player.library = library
                    // Route playback events to the scrobbler.
                    player.onTrackStarted = { [scrobbler] track in
                        scrobbler.nowPlaying(track)
                    }
                    player.onTrackFinished = { [scrobbler] track, played in
                        scrobbler.trackFinished(track, played: played)
                    }
                    player.onScrobbleEligible = { [scrobbler] track in
                        scrobbler.scrobbleEligible(track)
                    }
                    scrobbler.start()
                    // Music pushed from the Mac lands in Documents while the app is on
                    // screen, so no activation follows it — the receiver asks for the
                    // rescan itself once a batch has settled.
                    receiver.onFinished = { [library] in await library.rescanUntilSettled() }
                    receiver.start()
                    DemoLibrary.seedIfNeeded()
                    await library.loadFromDatabase()
                    await library.rescan()

                    if GaplessSelfTest.isEnabled {
                        await GaplessSelfTest.run(player: player, library: library)
                    }
                    if SwitchNoiseSelfTest.isEnabled {
                        await SwitchNoiseSelfTest.run(player: player, library: library)
                    }
                    if SkipScrobbleSelfTest.isEnabled {
                        await SkipScrobbleSelfTest.run(player: player, library: library)
                    }
                    if PlayheadSelfTest.isEnabled {
                        await PlayheadSelfTest.run(player: player, library: library)
                    }
                    if ScrobbleSelfTest.isEnabled {
                        await ScrobbleSelfTest.run(scrobbler: scrobbler, database: library.database)
                    }
                    if ArtworkSelfTest.isEnabled {
                        await ArtworkSelfTest.run(library: library)
                    }
                    // Credentials come from the environment, never from Secrets.swift:
                    // a literal there ships inside the App Store binary.
                    if let user = ProcessInfo.processInfo.environment["MUON_LOGIN_TEST_USER"],
                       let password = ProcessInfo.processInfo.environment["MUON_LOGIN_TEST_PASSWORD"] {
                        let ok = await scrobbler.logIn(username: user, password: password)
                        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                        try? "ok=\(ok) loggedIn=\(scrobbler.isLoggedIn) user=\(scrobbler.username ?? "nil") err=\(scrobbler.lastError ?? "none")"
                            .write(to: docs.appendingPathComponent("login.done"), atomically: true, encoding: .utf8)
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
