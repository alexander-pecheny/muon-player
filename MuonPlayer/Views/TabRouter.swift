import SwiftUI
import Observation

/// Identifies a selectable slot in the tab bar. A dedicated `.more` slot backs
/// our own overflow tab, replacing the system "More" tab (whose extra
/// UINavigationController is what produced the doubled navigation bar / back
/// button on folded-in screens).
enum TabSelection: Hashable {
    case tab(AppTab)
    case more
}

/// Owns the selected tab and each slot's navigation path, so navigation can be
/// driven from outside a tab's own view tree — e.g. deep-linking to an artist or
/// album from the Now Playing sheet, which is presented above the whole TabView
/// and therefore can't reach any single tab's NavigationStack directly.
@MainActor
@Observable
final class TabRouter {
    var selection: TabSelection = .tab(.albums)
    private var paths: [TabSelection: NavigationPath] = [:]

    func path(for slot: TabSelection) -> Binding<NavigationPath> {
        Binding(
            get: { self.paths[slot] ?? NavigationPath() },
            set: { self.paths[slot] = $0 }
        )
    }

    /// Push a destination onto the currently-selected slot's stack. Every slot
    /// registers the Album / ArtistRef destinations, so this works from any tab.
    func push<V: Hashable>(_ value: V) {
        var p = paths[selection] ?? NavigationPath()
        p.append(value)
        paths[selection] = p
    }

    func openArtist(_ name: String) { push(ArtistRef(name: name)) }

    /// `focus` is the path of a track to scroll to — set when the user tapped a
    /// song name rather than an album name.
    func openAlbum(_ album: Album, focus: String? = nil) {
        if let focus { push(AlbumRef(album: album, focusPath: focus)) } else { push(album) }
    }
}
