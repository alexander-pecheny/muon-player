import SwiftUI

struct ContentView: View {
    @Environment(Player.self) private var player
    @State private var showNowPlaying = false

    var body: some View {
        TabView {
            NavigationStack {
                AlbumsView()
                    .navigationTitle("Albums")
            }
            .tabItem { Label("Albums", systemImage: "square.stack") }

            NavigationStack {
                SongsView()
                    .navigationTitle("Songs")
            }
            .tabItem { Label("Songs", systemImage: "music.note.list") }

            NavigationStack {
                SearchView()
                    .navigationTitle("Search")
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
        }
        .safeAreaInset(edge: .bottom) {
            if player.currentTrack != nil {
                MiniPlayer(onTap: { showNowPlaying = true })
            }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
    }
}
