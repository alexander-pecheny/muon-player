import Observation
import SwiftUI

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

    /// Names of the pages pushed onto the current slot's path, so a tab can call
    /// itself after what it is showing. `NavigationPath` will not say what is in
    /// it, so the destinations report their own names (`tabTitle`).
    var crumbs: [Slot: [String]] = [:]

    init(slot: Slot) { self.slot = slot }

    var title: String { crumbs[slot]?.last ?? slot.defaultTitle }

    var path: NavigationPath { paths[slot] ?? NavigationPath() }

    /// Record `title` as the name of the page now on top, and drop names left
    /// behind by a pop.
    func name(_ title: String) {
        var names = crumbs[slot] ?? []
        let depth = path.count
        guard depth > 0 else { return }
        if names.count < depth { names.append(title) } else { names[depth - 1] = title }
        crumbs[slot] = names
    }

    func truncateCrumbs(to depth: Int) {
        if let names = crumbs[slot], names.count > depth {
            crumbs[slot] = Array(names.prefix(depth))
        }
    }

    func push<V: Hashable>(_ value: V, named title: String) {
        var p = paths[slot] ?? NavigationPath()
        p.append(value)
        paths[slot] = p
        crumbs[slot] = (crumbs[slot] ?? []) + [title]
    }
}
