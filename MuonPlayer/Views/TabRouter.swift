import SwiftUI
import Observation

/// Identifies a selectable slot in the tab bar. A dedicated `.more` slot backs
/// our own overflow tab, replacing the system "More" tab (whose extra
/// UINavigationController is what produced the doubled navigation bar / back
/// button on folded-in screens).
enum TabSelection: Hashable, BrowseSlot {
    case tab(AppTab)
    case more

    var defaultTitle: String {
        switch self {
        case .tab(let t): return t.title
        case .more: return "More"
        }
    }

    var systemImage: String {
        switch self {
        case .tab(let t): return t.systemImage
        case .more: return "ellipsis"
        }
    }

    /// `AppTab.more` does not exist, and no `AppTab` rawValue is "more" (Home's
    /// is "search"), so the two cases cannot collide in UserDefaults.
    var rawValue: String {
        switch self {
        case .tab(let t): return t.rawValue
        case .more: return "more"
        }
    }

    init(rawValue: String) {
        self = AppTab(rawValue: rawValue).map(TabSelection.tab) ?? .more
    }
}

/// Owns the open browsing contexts, the selected tab within the active one, and
/// each slot's navigation path — so navigation can be driven from outside a tab's
/// own view tree, e.g. deep-linking to an artist or album from the Now Playing
/// sheet, which is presented above the whole TabView.
///
/// The bottom bar picks the slot *within* the active context, exactly as the
/// macOS sidebar does. Every context therefore keeps its own stack per slot, so
/// nothing about the one-context app changes until a second context exists.
@MainActor
@Observable
final class TabRouter {
    typealias Context = BrowseContext<TabSelection>

    private(set) var contexts: [Context]
    private(set) var activeID: Context.ID

    /// Raised by the tab-count button; ContentView presents the switcher above
    /// the whole TabView, the way it presents Now Playing.
    var showSwitcher = false

    /// True when the open tabs came back from the last session, which is what
    /// tells ContentView not to overrule the restored selection.
    let restored: Bool

    init() {
        let saved = (UserDefaults.standard.array(forKey: Self.key) as? [String] ?? [])
            .map(TabSelection.init(rawValue:))
        restored = !saved.isEmpty
        let slots = saved.isEmpty ? [TabSelection.tab(.albums)] : saved
        let open = slots.map(Context.init(slot:))
        contexts = open
        activeID = open[min(max(0, UserDefaults.standard.integer(forKey: Self.activeKey)), open.count - 1)].id
    }

    var active: Context { contexts.first { $0.id == activeID } ?? contexts[0] }

    var selection: TabSelection {
        get { active.slot }
        set { active.slot = newValue; persist() }
    }

    func path(for slot: TabSelection) -> Binding<NavigationPath> {
        Binding(
            get: { self.active.paths[slot] ?? NavigationPath() },
            set: { new in
                self.active.paths[slot] = new
                if slot == self.active.slot { self.active.truncateCrumbs(to: new.count) }
            }
        )
    }

    /// Called by a pushed page to name itself, which is what its tab is called
    /// while that page is showing.
    func nameCurrentPage(_ title: String) { active.name(title) }

    // MARK: - Tabs

    /// A new tab starts on Home. When Home has been reordered into the overflow
    /// it is pushed onto the More stack instead of leaving the tab on the More
    /// list, so a new tab shows Home whatever the tab order.
    func newTab(_ settings: TabSettings) {
        let slot = settings.reachable(.tab(.home))
        let context = Context(slot: slot)
        if slot == .more { context.push(AppTab.home, named: AppTab.home.title) }
        contexts.insert(context, at: (contexts.firstIndex { $0.id == activeID } ?? contexts.count - 1) + 1)
        activeID = context.id
        persist()
    }

    func activate(_ id: Context.ID) {
        guard contexts.contains(where: { $0.id == id }) else { return }
        activeID = id
        persist()
    }

    @discardableResult
    func closeTab(_ id: Context.ID) -> Bool {
        guard contexts.count > 1, let i = contexts.firstIndex(where: { $0.id == id }) else { return false }
        contexts.remove(at: i)
        if activeID == id { activeID = contexts[min(i, contexts.count - 1)].id }
        persist()
        return true
    }

    /// Fold any restored slot that has since been pushed into the overflow onto
    /// the More tab, or the TabView would be told to select a tag it has not got.
    func reconcileSlots(with settings: TabSettings) {
        for context in contexts { context.slot = settings.reachable(context.slot) }
    }

    // MARK: - Persistence

    /// Which slots were open, and which tab was in front. Navigation history is
    /// not restorable — `NavigationPath` holds arbitrary values — so a tab comes
    /// back at its slot's root.
    private static let key = "iosTabs"
    private static let activeKey = "iosTabsActive"

    private func persist() {
        UserDefaults.standard.set(contexts.map(\.slot.rawValue), forKey: Self.key)
        UserDefaults.standard.set(contexts.firstIndex { $0.id == activeID } ?? 0, forKey: Self.activeKey)
    }

    // MARK: - Deep links

    func openArtist(_ name: String) {
        active.push(ArtistRef(name: name), named: name)
    }

    /// `focus` is the path of a track to scroll to — set when the user tapped a
    /// song name rather than an album name.
    func openAlbum(_ album: Album, focus: String? = nil) {
        if let focus {
            active.push(AlbumRef(album: album, focusPath: focus), named: album.title)
        } else {
            active.push(album, named: album.title)
        }
    }

    func openFolder(_ url: URL) {
        active.push(FolderRef(url: url), named: url.lastPathComponent)
    }
}

extension View {
    /// Name the tab after this page for as long as it is showing.
    func tabTitle(_ title: String) -> some View {
        modifier(TabTitle(title: title))
    }
}

private struct TabTitle: ViewModifier {
    @Environment(TabRouter.self) private var router
    let title: String

    func body(content: Content) -> some View {
        content.onAppear { router.nameCurrentPage(title) }
    }
}
