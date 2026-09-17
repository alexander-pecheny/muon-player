import Foundation

/// Cover images sitting beside the music. Used when a track carries no embedded
/// artwork of its own, which is the normal state of a folder full of Opus or of a
/// rip whose tagger never bothered.
enum FolderArt {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif"]

    /// Lower is better. A file called `cover` is what the folder means by its
    /// cover; anything else is a guess, and a picture of the back of the sleeve
    /// beats no picture at all.
    static func rank(_ name: String) -> Int? {
        let url = URL(fileURLWithPath: name)
        guard extensions.contains(url.pathExtension.lowercased()) else { return nil }
        switch url.deletingPathExtension().lastPathComponent.lowercased() {
        case "cover": return 0
        case "folder": return 1
        case "front": return 2
        case "album", "albumart", "albumartsmall": return 3
        default: return 4
        }
    }

    /// Folder → its best cover image, for every folder under the roots.
    ///
    /// A full walk, unlike the audio pass beside it: a cover dropped into a folder
    /// moves no track's mtime, and the folder index cannot say which folders once
    /// held one. It runs only when a pass found something to do, so an idle scan
    /// still costs a stat per folder.
    static func scan(roots: [URL]) -> [String: String] {
        let fm = FileManager.default
        var best: [String: (rank: Int, path: String)] = [:]
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                guard let rank = rank(url.lastPathComponent) else { continue }
                let folder = url.deletingLastPathComponent().path
                if best[folder] == nil || rank < best[folder]!.rank {
                    best[folder] = (rank, url.path)
                }
            }
        }
        return best.mapValues(\.path)
    }
}
