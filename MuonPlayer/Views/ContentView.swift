import SwiftUI

struct ContentView: View {
    @Environment(Player.self) private var player
    @Environment(TabSettings.self) private var tabSettings
    @Environment(TabRouter.self) private var router
    @State private var showNowPlaying = false
    @State private var didInitSelection = false

    // iOS shows at most 5 items on the iPhone tab bar. With more than that, we
    // reserve the last slot for our own More tab and fold the rest into it —
    // rather than letting iOS build its automatic More tab, whose extra
    // navigation controller doubled the bar/back button on folded-in screens.
    private var barLimit: Int { tabSettings.order.count > 5 ? 4 : tabSettings.order.count }
    private var visibleTabs: [AppTab] { Array(tabSettings.order.prefix(barLimit)) }
    private var overflowTabs: [AppTab] { Array(tabSettings.order.dropFirst(barLimit)) }

    var body: some View {
        content
            .sheet(isPresented: $showNowPlaying) { NowPlayingView() }
            .onAppear {
                if !didInitSelection {
                    didInitSelection = true
                    if let first = tabSettings.order.first { router.selection = .tab(first) }
                }
            }
    }

    // IMPORTANT: the mini-player modifier is applied UNCONDITIONALLY (the
    // playing-check lives *inside* the accessory/inset content). Wrapping the
    // whole TabView in `if playing { … } else { … }` changes its structural
    // identity the first time a track starts, which reset the tab selection and
    // popped any pushed navigation. Keeping the modifier constant avoids that.
    @ViewBuilder private var content: some View {
        if #available(iOS 26.0, *) {
            tabs.tabViewBottomAccessory {
                if player.currentTrack != nil {
                    MiniAccessory(onTap: { showNowPlaying = true })
                }
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
                .modifier(CommonDestinations())
        }
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
            .navigationDestination(for: AppTab.self) { TabRootView(tab: $0) }
            .modifier(CommonDestinations())
        }
        .environment(\.navPath, path)
    }
}

/// The root content for a tab, with its title. Shared by the visible tabs and
/// the overflow (More) list so both render identically.
private struct TabRootView: View {
    let tab: AppTab

    var body: some View {
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

/// Value-based destinations registered once per navigation stack.
private struct CommonDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content
            .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
            .navigationDestination(for: ArtistRef.self) { ArtistView(artist: $0.name) }
            .navigationDestination(for: FolderRef.self) { FoldersView(directory: $0.url) }
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

                VStack(alignment: .leading, spacing: 1) {
                    Text(player.currentTrack?.title ?? "")
                        .font(.subheadline.weight(.medium)).lineLimit(1)
                    if let artist = player.currentTrack?.artist {
                        Text(artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
