import SwiftUI

/// Artist / album navigation for a song row. On iOS a row's tap plays the track,
/// so the way to reach the artist or the album it belongs to is the long-press
/// menu — nesting buttons inside a row that already owns the tap does not work.
struct TrackNavigationMenu: View {
    let track: Track
    @Environment(LibraryStore.self) private var library
    @Environment(TabRouter.self) private var router
    @Environment(\.navPath) private var navPath

    var body: some View {
        Button { navPath?.wrappedValue.append(ArtistRef(name: track.effectiveAlbumArtist)) } label: {
            Label("Go to Artist", systemImage: "music.mic")
        }
        if let album = library.album(for: track) {
            Button { navPath?.wrappedValue.append(AlbumRef(album: album, focusPath: track.url.path)) } label: {
                Label("Go to Album", systemImage: "square.stack")
            }
            Button { router.openAlbum(album, focus: track.url.path, inNewTab: true) } label: {
                Label("Open Album in New Tab", systemImage: "square.on.square")
            }
        }
    }
}
