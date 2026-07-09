import Observation
import SwiftUI

/// The folders the user has added to the library, persisted as security-scoped
/// bookmarks.
///
/// The sandbox only grants access to a folder the user picked, and only for the
/// life of the process — a bookmark is what carries that grant across launches.
/// Access is opened once here and never relinquished, because the scanner, the
/// decoder and the tag writer all reach into these folders for as long as the
/// app runs.
@MainActor
@Observable
final class LibraryFolders {
    private(set) var roots: [LibraryRoot] = []

    private static let key = "libraryBookmarks"
    private var bookmarks: [Data] = []

    var isEmpty: Bool { roots.isEmpty }

    init() {
        // `bookmarks[i]` must describe `roots[i]`, so a bookmark that no longer
        // resolves (folder deleted, volume gone) is dropped from both.
        let stored = UserDefaults.standard.array(forKey: Self.key) as? [Data] ?? []
        var kept: [(Data, LibraryRoot)] = []
        for data in stored {
            guard let (url, refreshed) = Self.resolve(data) else { continue }
            kept.append((refreshed ?? data, LibraryRoot(url)))
        }
        bookmarks = kept.map(\.0)
        roots = kept.map(\.1)
        if bookmarks != stored { persist() }
    }

    /// Present the folder picker and add whatever the user chose. Returns true if
    /// the set of folders changed.
    @discardableResult
    func promptToAdd() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Library"
        panel.message = "Choose one or more folders to index."
        guard panel.runModal() == .OK else { return false }
        return add(panel.urls)
    }

    @discardableResult
    func add(_ urls: [URL]) -> Bool {
        var added = false
        for url in urls {
            let root = LibraryRoot(url)
            guard !roots.contains(where: { $0.path == root.path }) else { continue }
            guard let data = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            bookmarks.append(data)
            roots.append(root)
            added = true
        }
        if added { persist() }
        return added
    }

    func remove(_ root: LibraryRoot) {
        guard let i = roots.firstIndex(of: root) else { return }
        root.url.stopAccessingSecurityScopedResource()
        roots.remove(at: i)
        bookmarks.remove(at: i)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(bookmarks, forKey: Self.key)
    }

    /// Resolve a bookmark and open access to it. A stale bookmark still resolves
    /// (the folder merely moved), so it is re-minted rather than dropped; the
    /// fresh data is returned so the caller can persist it.
    private static func resolve(_ data: Data) -> (url: URL, refreshed: Data?)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        let refreshed = stale ? try? url.bookmarkData(options: .withSecurityScope,
                                                      includingResourceValuesForKeys: nil,
                                                      relativeTo: nil) : nil
        return (url, refreshed)
    }
}
