import SwiftUI

struct ContentView: View {
    @Environment(Player.self) private var player
    @Environment(TabSettings.self) private var tabSettings
    @Environment(TabRouter.self) private var router
    @State private var showNowPlaying = false
    @State private var didInitSelection = false

    private var visibleTabs: [AppTab] { tabSettings.visibleTabs }
    private var overflowTabs: [AppTab] { tabSettings.overflowTabs }

    var body: some View {
        content
            // App-wide tint follows the current track's artwork (mini player,
            // tab bar selection, buttons, swipe actions…). See DominantColor.
            .tint(player.accentColor)
            .sheet(isPresented: $showNowPlaying) { NowPlayingView() }
            .sheet(isPresented: Binding(get: { router.showSwitcher },
                                        set: { router.showSwitcher = $0 })) {
                TabSwitcherView()
            }
            .onAppear {
                if !didInitSelection {
                    didInitSelection = true
                    router.reconcileSlots(with: tabSettings)
                    // Only choose a tab when there was nothing to restore.
                    if !router.restored, let first = tabSettings.order.first {
                        router.selection = .tab(first)
                    }
                }
            }
    }

    // The mini-player is gated on `currentTrack` so there's no empty glass
    // accessory / inset before anything has played. The gate must not change
    // the view tree: swapping the modifier in rebuilds the TabView, and every
    // pushed page comes back with empty state and reloads in view — an album
    // page flashed "Album Is Gone" whenever a track started. Only iOS 26.0,
    // which lacks the flag, still pays that.
    @ViewBuilder private var content: some View {
        if #available(iOS 26.1, *) {
            tabs.tabViewBottomAccessory(isEnabled: player.currentTrack != nil) {
                MiniAccessory(onTap: { showNowPlaying = true })
            }
        } else if #available(iOS 26.0, *) {
            if player.currentTrack != nil {
                tabs.tabViewBottomAccessory {
                    MiniAccessory(onTap: { showNowPlaying = true })
                }
            } else {
                tabs
            }
        } else {
            tabs.safeAreaInset(edge: .bottom) {
                if player.currentTrack != nil {
                    MiniPlayer(onTap: { showNowPlaying = true })
                }
            }
        }
    }

    private var tabs: some View {
        @Bindable var router = router
        return TabView(selection: $router.selection) {
            ForEach(visibleTabs) { tab in
                TabNavStack(tab: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(TabSelection.tab(tab))
            }
            if !overflowTabs.isEmpty {
                MoreTab(tabs: overflowTabs)
                    .tabItem { Label("More", systemImage: "ellipsis") }
                    .tag(TabSelection.more)
            }
        }
    }
}

/// One tab's navigation container. All value-based destinations (`Album`,
/// `ArtistRef`, `FolderRef`) are declared exactly once here, at the stack root —
/// never on a pushed view. Registering a `navigationDestination` on a view *as
/// it is being pushed* (as the old per-view registrations did) made SwiftUI
/// re-resolve the stack mid-transition, which showed up as the first tap into an
/// album bouncing back / animating the wrong way. Centralising them fixes that
/// and also collapses the folder browser's per-level duplicate registration.
private struct TabNavStack: View {
    let tab: AppTab
    @Environment(TabRouter.self) private var router

    var body: some View {
        let path = router.path(for: .tab(tab))
        NavigationStack(path: path) {
            TabRootView(tab: tab)
                .tabCountToolbar()
                .modifier(CommonDestinations())
        }
        // A tab is its own browsing context, so switching to one rebuilds the
        // stack rather than animating the old one into the new path.
        .id(router.activeID)
        .environment(\.navPath, path)
    }
}

/// Our own overflow tab — a single NavigationStack listing the folded-in tabs.
/// Because everything lives in one stack, drilling into (say) Settings → About
/// produces exactly one navigation bar and one back button.
private struct MoreTab: View {
    let tabs: [AppTab]
    @Environment(TabRouter.self) private var router

    var body: some View {
        let path = router.path(for: .more)
        NavigationStack(path: path) {
            List(tabs) { tab in
                NavigationLink(value: Route.section(tab.rawValue)) {
                    Label(tab.title, systemImage: tab.systemImage)
                }
            }
            .navigationTitle("More")
            .tabCountToolbar()
            .modifier(CommonDestinations())
        }
        .id(router.activeID)
        .environment(\.navPath, path)
    }
}

/// The root content for a tab, with its title. Shared by the visible tabs and
/// the overflow (More) list so both render identically. A library scan affects
/// every tab, so the scan status overlay lives here rather than on one screen.
private struct TabRootView: View {
    @Environment(LibraryStore.self) private var library
    let tab: AppTab

    var body: some View {
        rootContent
            .overlay(alignment: .bottom) {
                if library.isScanning, let p = library.scanProgress {
                    ScanStatusCapsule(done: p.done, total: p.total)
                }
            }
    }

    @ViewBuilder private var rootContent: some View {
        switch tab {
        case .albums: AlbumsView().navigationTitle("Albums")
        case .artists: ArtistsView().navigationTitle("Artists")
        case .songs: SongsView().navigationTitle("Songs")
        case .folders: FoldersView().navigationTitle("Folders")
        case .home: HomeView().navigationTitle("Home")
        case .history: HistoryView().navigationTitle("History")
        case .settings: SettingsView().navigationTitle("Settings")
        }
    }
}

/// The "Scanning N/M…" pill shown while the library indexes. Uses tabular
/// (monospaced) digits so the counter doesn't jitter its width as it counts up.
private struct ScanStatusCapsule: View {
    let done: Int
    let total: Int

    var body: some View {
        Text("Scanning \(done)/\(total)…")
            .font(.caption.monospacedDigit())
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 4)
    }
}

/// Every pushed page, registered once per navigation stack.
private struct CommonDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: Route.self) { route in
            Group {
                switch route {
                case .album(let album): AlbumDetailView(album: album)
                case .albumRef(let ref): AlbumDetailView(album: ref.album, focusPath: ref.focusPath)
                case .artist(let ref): ArtistView(artist: ref.name)
                case .folder(let ref): FoldersView(directory: ref.url)
                case .section(let raw): TabRootView(tab: AppTab(rawValue: raw) ?? .home)
                }
            }
            .tabCountToolbar()
        }
    }
}

/// Lets a deeply-pushed view (e.g. AlbumDetailView's "Go to Artist") push onto
/// its enclosing tab stack without registering its own `navigationDestination`.
private struct NavPathKey: EnvironmentKey {
    static let defaultValue: Binding<[Route]>? = nil
}

extension EnvironmentValues {
    var navPath: Binding<[Route]>? {
        get { self[NavPathKey.self] }
        set { self[NavPathKey.self] = newValue }
    }
}
