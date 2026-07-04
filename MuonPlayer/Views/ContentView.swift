import SwiftUI

struct ContentView: View {
    @Environment(Player.self) private var player
    @Environment(TabSettings.self) private var tabSettings
    @State private var showNowPlaying = false
    @State private var selection: AppTab = .albums
    @State private var didInitSelection = false

    var body: some View {
        content
            .sheet(isPresented: $showNowPlaying) { NowPlayingView() }
            .onAppear {
                if !didInitSelection {
                    didInitSelection = true
                    if let first = tabSettings.order.first { selection = first }
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
        TabView(selection: $selection) {
            ForEach(tabSettings.order) { tab in
                TabNavStack(tab: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
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
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
                .navigationDestination(for: ArtistRef.self) { ArtistView(artist: $0.name) }
                .navigationDestination(for: FolderRef.self) { FoldersView(directory: $0.url) }
        }
        .environment(\.navPath, $path)
    }

    @ViewBuilder private var root: some View {
        switch tab {
        case .albums: AlbumsView().navigationTitle("Albums")
        case .artists: ArtistsView().navigationTitle("Artists")
        case .songs: SongsView().navigationTitle("Songs")
        case .folders: FoldersView().navigationTitle("Folders")
        case .search: SearchView().navigationTitle("Search")
        case .history: HistoryView().navigationTitle("History")
        case .settings: SettingsView().navigationTitle("Settings")
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
