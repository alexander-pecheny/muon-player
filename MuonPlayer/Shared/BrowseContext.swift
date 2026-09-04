import Observation
import SwiftUI

/// What kind of page a tab is showing, which is what its card calls itself
/// under the page's own name.
enum PageKind {
    case album, artist, folder
    /// A section shown as a page rather than as a bottom-bar slot — Home, when it
    /// has been reordered into the overflow. Its name already says what it is.
    case section

    var label: String? {
        switch self {
        case .album: return "Album"
        case .artist: return "Artist"
        case .folder: return "Folder"
        case .section: return nil
        }
    }
}

/// A slot a browsing context can be parked in — a sidebar section on macOS, a
/// bottom-bar tab on iOS.
protocol BrowseSlot: Hashable {
    /// What a context in this slot is called before anything is pushed onto it.
    var defaultTitle: String { get }
}

/// One tab: a whole browsing context. It owns the slot it is showing and a
/// navigation path per slot, so moving between slots inside a context and coming
/// back restores where you were — which is what the single-context app did.
@MainActor
@Observable
final class BrowseContext<Slot: BrowseSlot>: Identifiable {
    let id = UUID()
    var slot: Slot

    /// macOS only: the omni-search query is part of what a tab is showing, so
    /// switching tabs brings its search back with it.
    var searchQuery = ""

    var paths: [Slot: NavigationPath] = [:]

    /// What each page pushed onto the current slot's path is called, and the
    /// cover to show for it. `NavigationPath` will not say what is in it, so the
    /// destinations report themselves (`tabTitle`).
    struct Crumb {
        let name: String
        let kind: PageKind
        let artworkPath: String?
    }

    var crumbs: [Slot: [Crumb]] = [:]

    init(slot: Slot) { self.slot = slot }

    var title: String { crumbs[slot]?.last?.name ?? slot.defaultTitle }
    var kind: PageKind? { crumbs[slot]?.last?.kind }
    var artworkPath: String? { crumbs[slot]?.last?.artworkPath }

    var path: NavigationPath { paths[slot] ?? NavigationPath() }

    /// Record the page now on top, and drop crumbs left behind by a pop.
    func name(_ title: String, kind: PageKind, artwork: String? = nil) {
        var names = crumbs[slot] ?? []
        let depth = path.count
        guard depth > 0 else { return }
        let crumb = Crumb(name: title, kind: kind, artworkPath: artwork)
        if names.count < depth { names.append(crumb) } else { names[depth - 1] = crumb }
        crumbs[slot] = names
    }

    func truncateCrumbs(to depth: Int) {
        if let names = crumbs[slot], names.count > depth {
            crumbs[slot] = Array(names.prefix(depth))
        }
    }

    func push<V: Hashable>(_ value: V, named title: String, kind: PageKind, artwork: String? = nil) {
        var p = paths[slot] ?? NavigationPath()
        p.append(value)
        paths[slot] = p
        crumbs[slot] = (crumbs[slot] ?? []) + [Crumb(name: title, kind: kind, artworkPath: artwork)]
    }
}
