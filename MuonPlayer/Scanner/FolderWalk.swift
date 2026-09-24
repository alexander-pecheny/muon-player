import Foundation

/// Walks the library's roots for audio files, skipping any folder whose mtime has
/// not moved since the last pass.
///
/// A folder's mtime changes whenever a direct child is created, deleted or renamed
/// — which covers every way music arrives, atomic saves included. So a folder at
/// its known mtime still holds exactly what it held last time, and the walk need
/// neither list it nor stat the files in it. An idle pass becomes one `stat` per
/// folder instead of a readdir per folder plus a stat per file.
enum FolderWalk {
    struct Result: Sendable {
        var files: [(path: String, url: URL, mtime: Double)] = []
        /// Folder → the audio file names it now holds. Only listed folders appear,
        /// and only they may be pruned.
        var listed: [String: Set<String>] = [:]
        var folderMtimes: [(path: String, mtime: Double)] = []
        /// Folders that are gone, renamed, or no longer folders.
        var gone: [String] = []
        var foldersStatted = 0
    }

    private static let keys: Set<URLResourceKey> =
        [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]

    /// `minAge` holds back the mtime of a folder written to that recently, so the
    /// next settle pass lists it again: a copy still in flight is not a state worth
    /// remembering. It is still recorded, at mtime 0, or its parent would be skipped
    /// as unchanged and nothing would ever walk down into it again.
    static func run(roots: [URL], known: [String: Double], listEverything: Bool,
                    minAge: TimeInterval, onProgress: (@Sendable (Int) -> Void)? = nil) -> Result {
        let fm = FileManager.default
        var children: [String: [String]] = [:]
        for path in known.keys {
            children[(path as NSString).deletingLastPathComponent, default: []].append(path)
        }

        var result = Result()
        var seen = Set<String>()
        let now = Date().timeIntervalSince1970

        for root in roots {
            var stack = [LibraryRoot.canonicalPath(of: root)]
            while let path = stack.popLast() {
                guard seen.insert(path).inserted else { continue }
                result.foldersStatted += 1

                let url = URL(fileURLWithPath: path)
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isDirectory == true,
                      let mtime = values.contentModificationDate?.timeIntervalSince1970 else {
                    result.gone.append(path)
                    continue
                }
                if !listEverything, known[path] == mtime {
                    stack.append(contentsOf: children[path] ?? [])
                    continue
                }
                guard let entries = try? fm.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
                    result.gone.append(path)
                    continue
                }

                var names = Set<String>()
                var subfolders = Set<String>()
                for entry in entries {
                    let values = try? entry.resourceValues(forKeys: keys)
                    // A symlinked folder would be walked twice under two paths, and
                    // a link back up the tree would never terminate.
                    if values?.isDirectory == true {
                        if values?.isSymbolicLink != true { subfolders.insert(entry.path) }
                    } else if AudioFormat.supportedExtensions.contains(entry.pathExtension.lowercased()) {
                        names.insert(entry.lastPathComponent)
                        result.files.append((entry.path, entry,
                                             values?.contentModificationDate?.timeIntervalSince1970 ?? 0))
                        if result.files.count % 200 == 0 { onProgress?(result.files.count) }
                    }
                }

                result.listed[path] = names
                stack.append(contentsOf: subfolders)
                result.gone.append(contentsOf: (children[path] ?? []).filter { !subfolders.contains($0) })
                result.folderMtimes.append((path, now - mtime >= minAge ? mtime : 0))
            }
        }

        onProgress?(result.files.count)
        return result
    }

    /// Every audio file under `root`, in path order — for the seam CLI and tests,
    /// neither of which has a folder index to diff against.
    static func audioFiles(under root: URL) -> [URL] {
        run(roots: [root], known: [:], listEverything: true, minAge: 0)
            .files.map(\.url)
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
