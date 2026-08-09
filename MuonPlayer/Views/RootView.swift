import SwiftUI

/// The app's screens plus the object graph they read from.
///
/// The Apple apps build that graph in their own `App` entry points, which own
/// scenes, an audio session and the launch self-tests. Android has no `App` of
/// its own — Skip bridges a single root view — so this is where the Android side
/// gets the same `Player`, `LibraryStore` and `ScrobbleService` the iOS screens
/// already expect in the environment.
public struct RootView: View {
    @State private var library: LibraryStore
    @State private var player = Player()
    @State private var scrobbler: ScrobbleService
    @State private var tabSettings = TabSettings()
    @State private var router = TabRouter()

    public init() {
        let lib = LibraryStore(roots: Self.savedRoots())
        _library = State(initialValue: lib)
        _scrobbler = State(initialValue: makeScrobbler(for: lib))
    }

    public var body: some View {
        ContentView()
            .environment(library)
            .environment(player)
            .environment(scrobbler)
            .environment(tabSettings)
            .environment(router)
            .task {
                player.library = library
                connectScrobbler(scrobbler, to: player)
                scrobbler.start()
                await library.loadFromDatabase()
                await library.rescan()
            }
    }

    /// The folder the user last indexed. Android keeps it in `Prefs` because
    /// `UserDefaults` does not survive a relaunch there; the Apple apps pass their
    /// own roots in and never reach this.
    private static func savedRoots() -> [LibraryRoot] {
        guard let path = Prefs.string(forKey: AndroidLibrary.rootKey) else { return [] }
        return [LibraryRoot(URL(fileURLWithPath: path))]
    }
}
