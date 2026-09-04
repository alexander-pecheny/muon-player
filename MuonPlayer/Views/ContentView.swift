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
    // accessory / inset before anything has played. Tab selection and pushed
    // navigation live in the external `router` (@Observable), so the TabView
    // rebuild when the accessory first appears re-reads them and nothing resets.
    @ViewBuilder private var content: some View {
        if #available(iOS 26.0, *) {
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
                NavigationLink(value: tab) {
                    Label(tab.title, systemImage: tab.systemImage)
                }
            }
            .navigationTitle("More")
            .navigationDestination(for: AppTab.self) {
                TabRootView(tab: $0).tabCountToolbar()
            }
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

/// Value-based destinations registered once per navigation stack.
private struct CommonDestinations: ViewModifier {
    @Environment(LibraryStore.self) private var library

    /// An artist has no art of its own; the app shows one of their covers, and
    /// the tab card follows suit.
    private func artistArtwork(_ name: String) -> String? {
        library.albums.first { $0.artist == name && $0.artworkPath != nil }?.artworkPath
    }

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: Album.self) {
                AlbumDetailView(album: $0).tabTitle($0.title, kind: .album, artwork: $0.artworkPath).tabCountToolbar()
            }
            .navigationDestination(for: AlbumRef.self) {
                AlbumDetailView(album: $0.album, focusPath: $0.focusPath)
                    .tabTitle($0.album.title, kind: .album, artwork: $0.album.artworkPath)
                    .tabCountToolbar()
            }
            .navigationDestination(for: ArtistRef.self) {
                ArtistView(artist: $0.name)
                    .tabTitle($0.name, kind: .artist, artwork: artistArtwork($0.name))
                    .tabCountToolbar()
            }
            .navigationDestination(for: FolderRef.self) {
                FoldersView(directory: $0.url)
                    .tabTitle($0.url.lastPathComponent, kind: .folder).tabCountToolbar()
            }
    }
}

/// Lets a deeply-pushed view (e.g. AlbumDetailView's "Go to Artist") push onto
/// its enclosing tab stack without registering its own `navigationDestination`.
private struct NavPathKey: EnvironmentKey {
    static let defaultValue: Binding<NavigationPath>? = nil
}

extension EnvironmentValues {
    var navPath: Binding<NavigationPath>? {
        get { self[NavPathKey.self] }
        set { self[NavPathKey.self] = newValue }
    }
}

/// Compact now-playing content for the iOS 26 tab-view bottom accessory. The
/// accessory itself provides the glass background.
private struct MiniAccessory: View {
    @Environment(Player.self) private var player
    var onTap: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 10) {
                artwork
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 0) {
                    Text(player.currentTrack?.title ?? "")
                        .font(.system(size: 14.5, weight: .medium)).lineLimit(1)
                    if let artist = player.currentTrack?.artist {
                        Text(artist).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)

                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.title3)
                }
                .buttonStyle(.plain)
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                }
                .buttonStyle(.plain)
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title3)
                }
                .buttonStyle(.plain)
            }
            MiniWaveform(height: 12)
        }
        // Lift the row off the accessory's top edge and sit it nearer the waveform.
        .padding(.top, 6)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder private var artwork: some View {
        if let art = player.currentArtwork {
            Image(uiImage: art).resizable().aspectRatio(contentMode: .fill)
        } else {
            ArtworkView(path: player.currentTrack?.url.path, cornerRadius: 5)
        }
    }
}
