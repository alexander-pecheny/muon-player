import Foundation

/// A folder the library indexes. Tracks are stored in SQLite by absolute path,
/// and every folder-scoped query matches on a root's `path` prefix — so a root
/// must carry the same canonical (symlink-resolved) form the file enumerator
/// produces, or no stored path would ever match it.
///
/// iOS has exactly one root (the app's Documents dir). macOS has as many as the
/// user adds.
struct LibraryRoot: Identifiable, Sendable, Hashable {
    let url: URL
    /// Canonical absolute path, no trailing slash.
    let path: String

    var id: String { path }
    var name: String { url.lastPathComponent }

    init(_ url: URL) {
        self.url = url
        self.path = LibraryRoot.canonicalPath(of: url)
    }

    /// The path of `absolute` relative to this root, or nil if it isn't under it.
    func relativePath(of absolute: String) -> String? {
        guard absolute.hasPrefix(path + "/") else { return nil }
        return String(absolute.dropFirst(path.count + 1))
    }

    /// The root's immediate child folder containing `absolute` (the artist
    /// folder, by this library's layout convention), as an absolute path. Nil for
    /// a file sitting directly in the root.
    func topFolder(of absolute: String) -> String? {
        guard let rel = relativePath(of: absolute) else { return nil }
        let comps = rel.split(separator: "/")
        guard comps.count >= 2 else { return nil }
        return path + "/" + comps[0]
    }

    /// `canonicalPath` resolves both symlinks and the `/var` → `/private/var`
    /// prefix that the directory enumerator bakes into every path it yields.
    /// `resolvingSymlinksInPath()` alone does not add `/private` on iOS.
    static func canonicalPath(of url: URL) -> String {
        (try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
            ?? url.resolvingSymlinksInPath().path
    }

    /// The app's Documents folder — the whole library on iOS, and where the
    /// simulator/Files app drops music.
    static var documents: LibraryRoot {
        LibraryRoot(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!)
    }
}
