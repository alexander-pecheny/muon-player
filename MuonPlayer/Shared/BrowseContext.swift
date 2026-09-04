import Observation
import SwiftUI

/// What kind of page a tab is showing, which is what its card calls itself
/// under the page's own name.
enum PageKind: String, Codable {
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

    /// A stable string for UserDefaults, so a restored tab lands where it was.
    var storageKey: String { get }
    init?(storageKey: String)
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
    struct Crumb: Codable {
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
        // A page that reports no art must not erase art we already had for it: an
        // artist's cover is looked up in the library, and on the launch after a
        // restore that page reappears before the library has finished loading.
        let existing = names.count >= depth ? names[depth - 1] : nil
        let keptArt = artwork ?? (existing?.name == title ? existing?.artworkPath : nil)
        let crumb = Crumb(name: title, kind: kind, artworkPath: keptArt)
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

// MARK: - Saving and restoring

extension BrowseContext {
    /// Everything a tab needs to come back: which slot it was on, and the whole
    /// stack behind each slot.
    ///
    /// The stack is the point. Persisting the slot alone brought every tab back
    /// at its section root, so an album tab reopened as "Albums" — the tabs were
    /// restored in name only. `NavigationPath` will encode itself as long as every
    /// value in it is `Codable`, which is why `Album` and the three refs are.
    private struct Snapshot: Codable {
        let slot: String
        let paths: [String: Data]
        let crumbs: [String: [Crumb]]
    }

    func snapshot() -> Data? {
        var encodedPaths: [String: Data] = [:]
        for (slot, path) in paths {
            guard let codable = path.codable,
                  let data = try? JSONEncoder().encode(codable) else { continue }
            encodedPaths[slot.storageKey] = data
        }
        let crumbsByKey = Dictionary(uniqueKeysWithValues: crumbs.map { ($0.key.storageKey, $0.value) })
        return try? JSONEncoder().encode(
            Snapshot(slot: slot.storageKey, paths: encodedPaths, crumbs: crumbsByKey))
    }

    convenience init?(snapshot data: Data) {
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              let slot = Slot(storageKey: snapshot.slot) else { return nil }
        self.init(slot: slot)

        for (key, data) in snapshot.paths {
            guard let slot = Slot(storageKey: key),
                  let codable = try? JSONDecoder().decode(NavigationPath.CodableRepresentation.self, from: data)
            else { continue }
            paths[slot] = NavigationPath(codable)
        }
        for (key, value) in snapshot.crumbs {
            if let slot = Slot(storageKey: key) { crumbs[slot] = value }
        }
    }
}
