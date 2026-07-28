import SwiftUI

@main
struct MuonPlayerMacApp: App {
    @State private var folders: LibraryFolders
    @State private var library: LibraryStore
    @State private var player = Player()
    @State private var scrobbler: ScrobbleService
    @State private var router = MacRouter()

    init() {
        let folders = LibraryFolders()
        // The self-test plays tracks, which records history and queues scrobbles.
        // Keep all of that out of the real library.
        let lib = LibraryStore(roots: folders.roots,
                               databaseName: MacSelfTest.isEnabled ? "muon-selftest.sqlite" : "muon-library.sqlite")
        _folders = State(initialValue: folders)
        _library = State(initialValue: lib)
        _scrobbler = State(initialValue: makeScrobbler(for: lib))
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environment(library)
                .environment(player)
                .environment(scrobbler)
                .environment(folders)
                .environment(router)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    player.library = library
                    connectScrobbler(scrobbler, to: player)
                    scrobbler.start()
                    await library.loadFromDatabase()
                    if !folders.isEmpty { await library.rescan() }

                    if MacSelfTest.isEnabled {
                        await MacSelfTest.run(player: player, library: library)
                    }
                }
        }
        .windowToolbarStyle(.unified)
        .commands { MuonCommands(player: player, library: library, folders: folders, router: router) }

        // A window rather than a sheet: a sheet tall enough for a cover resizes
        // the main window under it, which then stays displaced after it closes.
        WindowGroup(id: MacArtworkZoomView.windowID, for: String.self) { $path in
            if let path {
                MacArtworkZoomView(path: path).environment(library)
            }
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            MacSettingsView()
                .environment(library)
                .environment(scrobbler)
                .environment(folders)
        }
    }
}

/// Playback and library commands, mirrored into the menu bar so every action has
/// a keyboard shortcut. Space also toggles play/pause, but through a key monitor
/// rather than a menu shortcut — see SpaceTogglesPlayback.
struct MuonCommands: Commands {
    let player: Player
    let library: LibraryStore
    let folders: LibraryFolders
    let router: MacRouter

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .textEditing) {
            Button("Find") { router.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }

        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(player.currentTrack == nil)
            Button("Next Track") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous Track") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Picker("Mode", selection: Binding(get: { player.mode }, set: { player.mode = $0 })) {
                ForEach(PlaybackMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(mode)
                }
            }
            Divider()
            Button("Stop") { player.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(player.currentTrack == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Show Now Playing") { router.showNowPlaying.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }

        CommandMenu("Library") {
            Button("Add Folder to Library…") {
                if folders.promptToAdd() {
                    Task { await library.setRoots(folders.roots) }
                }
            }
            .keyboardShortcut("o", modifiers: .command)
            Button("Rescan Library") { Task { await library.rescan() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(library.isScanning || folders.isEmpty)
        }
    }
}
