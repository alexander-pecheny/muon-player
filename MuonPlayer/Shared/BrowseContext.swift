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

/// A page on a navigation stack. The stack is `[Route]` rather than a
/// `NavigationPath` so a tab can read its own title off the top of it, instead
/// of each page reporting its name as it appears: several pages appear at once
/// when a stack is restored or re-identified, and a cancelled swipe-back
/// re-appears the parent while the child is still on top. Both wrote the wrong
/// page's name over the top one's.
enum Route: Hashable, Codable {
    case album(Album)
    case albumRef(AlbumRef)
    case artist(ArtistRef)
    case folder(FolderRef)
    /// An `AppTab` raw value — `AppTab` is iOS-only, so the shared enum keeps the
    /// string.
    case section(String)

    var title: String {
        switch self {
        case .album(let album): return album.title
        case .albumRef(let ref): return ref.album.title
        case .artist(let ref): return ref.name
        case .folder(let ref): return ref.url.lastPathComponent
        case .section(let raw): return sectionTitle(raw)
        }
    }

    var kind: PageKind {
        switch self {
        case .album, .albumRef: return .album
        case .artist: return .artist
        case .folder: return .folder
        case .section: return .section
        }
    }

    /// nil for an artist: they have no cover of their own, so the switcher looks
    /// one of their albums up in the library.
    var artworkPath: String? {
        switch self {
        case .album(let album): return album.artworkPath
        case .albumRef(let ref): return ref.album.artworkPath
        case .artist, .folder, .section: return nil
        }
    }

    private func sectionTitle(_ raw: String) -> String {
        #if os(iOS)
        return AppTab(rawValue: raw)?.title ?? raw
        #else
        return raw
        #endif
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

    var paths: [Slot: [Route]] = [:]

    init(slot: Slot) { self.slot = slot }

    var path: [Route] { paths[slot] ?? [] }

    var title: String { path.last?.title ?? slot.defaultTitle }
    var kind: PageKind? { path.last?.kind }
    var artworkPath: String? { path.last?.artworkPath }

    func push(_ route: Route) { paths[slot, default: []].append(route) }
}

// MARK: - Saving and restoring

extension BrowseContext {
    /// Everything a tab needs to come back: which slot it was on, and the whole
    /// stack behind each slot.
    ///
    /// The stack is the point. Persisting the slot alone brought every tab back
    /// at its section root, so an album tab reopened as "Albums" — the tabs were
    /// restored in name only.
    private struct Snapshot: Codable {
        let slot: String
        let paths: [String: [Route]]
    }

    func snapshot() -> Data? {
        let byKey = Dictionary(uniqueKeysWithValues: paths.map { ($0.key.storageKey, $0.value) })
        return try? JSONEncoder().encode(Snapshot(slot: slot.storageKey, paths: byKey))
    }

    convenience init?(snapshot data: Data) {
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              let slot = Slot(storageKey: snapshot.slot) else { return nil }
        self.init(slot: slot)
        for (key, routes) in snapshot.paths {
            if let slot = Slot(storageKey: key) { paths[slot] = routes }
        }
    }
}
