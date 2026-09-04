import Observation
import SwiftUI

typealias BrowseTab = BrowseContext<MacRouter.Section>

/// The window's tabs, plus the deep links that push onto whichever one is active.
@MainActor
@Observable
final class MacRouter {
    enum Section: String, CaseIterable, Identifiable, BrowseSlot {
        case home, albums, artists, songs, folders, history
        var id: String { rawValue }
        var defaultTitle: String { title }

        var title: String {
            switch self {
            case .home: return "Home"
            case .albums: return "Albums"
            case .artists: return "Artists"
            case .songs: return "Songs"
            case .folders: return "Folders"
            case .history: return "History"
            }
        }

        var systemImage: String {
            switch self {
            case .home: return "house"
            case .albums: return "square.stack"
            case .artists: return "music.mic"
            case .songs: return "music.note.list"
            case .folders: return "folder"
            case .history: return "clock"
            }
        }
    }

    private(set) var tabs: [BrowseTab]
    private(set) var activeID: BrowseTab.ID

    var showNowPlaying = false
    var showQueue = false

    init() {
        let (sections, active) = Self.restored()
        let restored = sections.map(BrowseTab.init(slot:))
        tabs = restored
        activeID = restored[min(active, restored.count - 1)].id
    }

    var active: BrowseTab { tabs.first { $0.id == activeID } ?? tabs[0] }

    // MARK: - What the views see

    /// The active tab's section. Views and the sidebar bind to this, so they need
    /// to know nothing about tabs.
    var section: Section {
        get { active.slot }
        set { active.slot = newValue; persist() }
    }

    /// The always-visible omni-search query, per tab: it is part of what a tab is
    /// showing, so switching tabs brings its search back with it.
    var searchQuery: String {
        get { active.searchQuery }
        set { active.searchQuery = newValue }
    }

    var path: Binding<NavigationPath> {
        Binding(get: { self.active.path },
                set: { new in
                    self.active.paths[self.active.slot] = new
                    // A pop shortens the trail of names behind the tab's title.
                    self.active.truncateCrumbs(to: new.count)
                })
    }

    /// Bumped by the ⌘F menu command; the toolbar field watches it to grab focus
    /// (a Commands scene can't reach a view's `@FocusState` directly).
    var searchFocusToken = 0
    func focusSearch() { searchFocusToken += 1 }

    /// Called by a pushed page to name itself, which is what the tab is called
    /// while that page is showing.
    func nameCurrentPage(_ title: String) { active.name(title) }

    /// Pop the current section back to its root, so a search typed while drilled
    /// into an album lands on the results rather than staying hidden behind it.
    func popToRoot() {
        active.paths[active.slot] = NavigationPath()
        active.crumbs[active.slot] = []
    }

    // MARK: - Tabs

    func newTab(section: Section? = nil, activate: Bool = true) {
        let tab = BrowseTab(slot: section ?? active.slot)
        tabs.insert(tab, at: (tabs.firstIndex { $0.id == activeID } ?? tabs.count - 1) + 1)
        if activate { activateTab(tab.id) }
        persist()
    }

    func activateTab(_ id: BrowseTab.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeID = id
        persist()
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activateTab(tabs[index].id)
    }

    /// Closing the last tab is the caller's cue to close the window instead.
    @discardableResult
    func closeTab(_ id: BrowseTab.ID) -> Bool {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == id }) else { return false }
        tabs.remove(at: i)
        if activeID == id { activeID = tabs[min(i, tabs.count - 1)].id }
        persist()
        return true
    }

    @discardableResult
    func closeActiveTab() -> Bool { closeTab(activeID) }

    // MARK: - Deep links

    /// ⌘-click opens in a background tab, as it does in a browser. Reading the
    /// modifier here rather than at each call site is what makes that true of
    /// every way into an album — the grid, search results, the player bar.
    private func push<V: Hashable>(_ value: V, named title: String, inNewTab: Bool = false) {
        showQueue = false
        let tab: BrowseTab
        if inNewTab || NSEvent.modifierFlags.contains(.command) {
            tab = BrowseTab(slot: active.slot)
            tabs.insert(tab, at: (tabs.firstIndex { $0.id == activeID } ?? tabs.count - 1) + 1)
            persist()
        } else {
            tab = active
        }
        tab.push(value, named: title)
    }

    func openArtist(_ name: String, inNewTab: Bool = false) {
        push(ArtistRef(name: name), named: name, inNewTab: inNewTab)
    }

    /// `focus` is the path of a track to scroll to — set when the user clicked a
    /// song name rather than an album name.
    func openAlbum(_ album: Album, focus: String? = nil, inNewTab: Bool = false) {
        if let focus {
            push(AlbumRef(album: album, focusPath: focus), named: album.title, inNewTab: inNewTab)
        } else {
            push(album, named: album.title, inNewTab: inNewTab)
        }
    }

    func openFolder(_ url: URL, inNewTab: Bool = false) {
        push(FolderRef(url: url), named: url.lastPathComponent, inNewTab: inNewTab)
    }

    // MARK: - Persistence

    /// Which sections were open, and which tab was in front. Navigation history
    /// is not restorable — `NavigationPath` holds arbitrary values — so a tab
    /// comes back at its section root.
    private static let key = "browseTabs"
    private static let activeKey = "browseTabsActive"

    private func persist() {
        UserDefaults.standard.set(tabs.map(\.slot.rawValue), forKey: Self.key)
        UserDefaults.standard.set(tabs.firstIndex { $0.id == activeID } ?? 0, forKey: Self.activeKey)
    }

    private static func restored() -> ([Section], Int) {
        let raw = UserDefaults.standard.array(forKey: key) as? [String] ?? []
        let sections = raw.compactMap(Section.init(rawValue:))
        guard !sections.isEmpty else { return ([.albums], 0) }
        return (sections, max(0, UserDefaults.standard.integer(forKey: activeKey)))
    }
}

extension View {
    /// Name the tab after this page for as long as it is showing.
    func tabTitle(_ title: String) -> some View {
        modifier(TabTitle(title: title))
    }
}

private struct TabTitle: ViewModifier {
    @Environment(MacRouter.self) private var router
    let title: String

    func body(content: Content) -> some View {
        content.onAppear { router.nameCurrentPage(title) }
    }
}
