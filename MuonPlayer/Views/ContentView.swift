import SwiftUI

struct ContentView: View {
    @Environment(Player.self) private var player
    @State private var showNowPlaying = false

    var body: some View {
        content
            .sheet(isPresented: $showNowPlaying) { NowPlayingView() }
    }

    @ViewBuilder private var content: some View {
        if #available(iOS 26.0, *) {
            // Native bottom accessory keeps the tab bar visible above the
            // mini player (like Apple Music's liquid-glass now-playing bar).
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
        TabView {
            NavigationStack {
                AlbumsView().navigationTitle("Albums")
            }
            .tabItem { Label("Albums", systemImage: "square.stack") }

            NavigationStack {
                SongsView().navigationTitle("Songs")
            }
            .tabItem { Label("Songs", systemImage: "music.note.list") }

            NavigationStack {
                SearchView().navigationTitle("Search")
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }

            NavigationStack {
                SettingsView().navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
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
